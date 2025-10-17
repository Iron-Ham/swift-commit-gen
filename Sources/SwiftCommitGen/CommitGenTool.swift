import Foundation

struct CommitGenTool {
  private let options: CommitGenOptions
  private let gitClient: GitClient
  private let summarizer: DiffSummarizer
  private let promptBuilder: PromptBuilder
  private let llmClient: LLMClient
  private let renderer: Renderer
  private let logger: CommitGenLogger
  private let consoleTheme: ConsoleTheme

  init(
    options: CommitGenOptions,
    gitClient: GitClient = SystemGitClient(),
    summarizer: DiffSummarizer? = nil,
    promptBuilder: PromptBuilder = DefaultPromptBuilder(),
    llmClient: LLMClient = FoundationModelsClient(),
    renderer: Renderer = ConsoleRenderer(),
    logger: CommitGenLogger = CommitGenLogger()
  ) {
    self.options = options
    self.gitClient = gitClient
    self.summarizer = summarizer ?? DefaultDiffSummarizer(gitClient: gitClient)
    self.promptBuilder = promptBuilder
    self.llmClient = llmClient
    self.renderer = renderer
    self.logger = logger
    self.consoleTheme = logger.consoleTheme
  }

  func run() async throws {
    let repoRoot = try await gitClient.repositoryRoot()
    logger.info("Repository root: \(repoRoot.path)")

    let status = try await gitClient.status()
    let scope: GitChangeScope = options.includeStagedOnly ? .staged : .all
    let changes = status.changes(for: scope)

    guard !changes.isEmpty else {
      throw CommitGenError.cleanWorkingTree
    }

    logger.info("Detected \(changes.count) pending change(s) in \(describe(scope: scope)) scope.")

    let summary = try await summarizer.summarize(
      status: status,
      includeStagedOnly: options.includeStagedOnly
    )
    logger.info(
      "Summary: \(summary.fileCount) file(s), +\(summary.totalAdditions) / -\(summary.totalDeletions)"
    )

    let branchName = (try? await gitClient.currentBranch()) ?? "HEAD"
    let repoName = repositoryName(from: repoRoot)
    let metadata = PromptMetadata(
      repositoryName: repoName,
      branchName: branchName,
      style: options.promptStyle,
      includeUnstagedChanges: !options.includeStagedOnly
    )

    let promptPackage = promptBuilder.makePrompt(summary: summary, metadata: metadata)
    if options.isVerbose {
      logPromptDiagnostics(promptPackage.diagnostics)
    }

    if options.outputFormat == .text {
      renderReviewSummary(summary)
    }

    logger.info("Requesting commit draft from the on-device language model…")
    var draft = try await llmClient.generateCommitDraft(from: promptPackage)
    renderer.render(draft, format: options.outputFormat, diagnostics: promptPackage.diagnostics)

    guard options.outputFormat == .text else {
      logger.info("JSON output requested; skipping interactive review.")
      logger.warning(
        "Automated commit application is not implemented yet; integrate the JSON payload into your workflow manually."
      )
      return
    }

    if let reviewedDraft = try await reviewDraft(
      initialDraft: draft,
      regenerate: { additionalContext in
        let package =
          additionalContext.map { promptPackage.appendingUserContext($0) }
          ?? promptPackage
        if options.isVerbose {
          logPromptDiagnostics(package.diagnostics)
        }
        return try await llmClient.generateCommitDraft(from: package)
      }
    ) {
      draft = reviewedDraft
      try await handleAcceptedDraft(draft, summary: summary, status: status)
    } else {
      logger.warning("Commit generation flow aborted; no changes were committed.")
    }
  }

  private func describe(scope: GitChangeScope) -> String {
    switch scope {
    case .staged:
      return "staged"
    case .unstaged:
      return "unstaged"
    case .all:
      return "staged + unstaged"
    }
  }

  private func repositoryName(from url: URL) -> String {
    let candidate = url.lastPathComponent
    return candidate.isEmpty ? url.path : candidate
  }

  private func reviewDraft(
    initialDraft: CommitDraft,
    regenerate: @escaping (_ additionalContext: String?) async throws -> CommitDraft
  ) async throws -> CommitDraft? {
    var currentDraft = initialDraft

    reviewLoop: while true {
      logger.info(
        "Options: [y] accept, [e] edit in $EDITOR, [r] regenerate, [c] regenerate with context, [n] abort"
      )
      guard let response = promptUser("Apply commit draft? [y/e/r/c/n]: ") else {
        continue
      }

      switch response {
      case "y", "yes":
        return currentDraft
      case "e", "edit":
        if let updated = try editDraft(currentDraft) {
          currentDraft = updated
          renderer.render(currentDraft, format: .text, diagnostics: nil)
        }
      case "r", "regen", "regenerate":
        logger.info("Requesting a new commit draft from the on-device language model…")
    currentDraft = try await regenerate(nil)
    renderer.render(currentDraft, format: .text, diagnostics: nil)
      case "c", "context":
        guard let additionalContext = promptForAdditionalContext() else {
          logger.warning("No additional context provided; keeping previous draft.")
          continue
        }
        logger.info("Requesting a new commit draft with user context…")
    currentDraft = try await regenerate(additionalContext)
    renderer.render(currentDraft, format: .text, diagnostics: nil)
      case "n", "no", "q", "quit":
        break reviewLoop
      default:
        logger.warning("Unrecognized option. Please respond with y, e, r, c, or n.")
      }
    }

    return nil
  }

  private func promptUser(_ prompt: String) -> String? {
    if let data = prompt.data(using: .utf8) {
      FileHandle.standardError.write(data)
    }
    guard let line = readLine() else {
      logger.warning("Unable to read response; aborting interaction.")
      return nil
    }
    return line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func promptForAdditionalContext() -> String? {
    logger.info(
      "Enter additional context for the next draft (blank line to finish, Ctrl+D to cancel):")

    var lines: [String] = []
    while let line = readLine() {
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedLine.isEmpty {
        break
      }
      lines.append(line)
    }

    let combined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return combined.isEmpty ? nil : combined
  }

  private func editDraft(_ draft: CommitDraft) throws -> CommitDraft? {
    let environment = ProcessInfo.processInfo.environment
    guard let editor = environment["EDITOR"], !editor.isEmpty else {
      logger.warning("$EDITOR is not set; skipping edit request.")
      return nil
    }

    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swiftcommitgen-\(UUID().uuidString).txt"
    )
    defer { try? FileManager.default.removeItem(at: tempURL) }

    var contents = draft.editorRepresentation
    contents.append("\n")
    try contents.write(to: tempURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "\(editor) \(tempURL.path)"]
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    process.environment = environment

    do {
      try process.run()
    } catch {
      logger.warning("Failed to launch $EDITOR (\(editor)): \(error.localizedDescription)")
      return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      logger.warning(
        "Editor exited with status \(process.terminationStatus); keeping previous draft."
      )
      return nil
    }

    let updatedContents = try String(contentsOf: tempURL, encoding: .utf8)
    let updatedDraft = CommitDraft.fromEditorContents(updatedContents)

    guard !updatedDraft.subject.isEmpty else {
      logger.warning("Edited draft has an empty subject; keeping previous draft.")
      return nil
    }

    return updatedDraft
  }

  private func handleAcceptedDraft(
    _ draft: CommitDraft,
    summary: ChangeSummary,
    status: GitStatus
  ) async throws {
    logger.info("Commit draft accepted.")

    guard options.autoCommit else {
      logger.warning(
        "Auto-commit disabled; run `git commit` manually or re-run with --commit to apply the draft automatically."
      )
      return
    }

    if !options.includeStagedOnly {
      let hasPending = !status.unstaged.isEmpty || !status.untracked.isEmpty
      if hasPending {
        guard options.stageChanges else {
          logger.warning(
            "Unstaged changes detected; re-run with --stage to stage them automatically. Commit skipped."
          )
          return
        }

        try await stageChanges(for: status)
        logger.info("Staged unstaged/untracked changes before committing.")
      }
    }

    try await gitClient.commit(message: draft.commitMessage)
    logger.info("Git commit created successfully.")
  }

  private func renderReviewSummary(_ summary: ChangeSummary) {
    guard !summary.files.isEmpty else { return }
    logger.info("Reviewing \(summary.fileCount) file(s):")
    for file in summary.files {
      let bullet = consoleTheme.applying(consoleTheme.muted, to: "  - ")
      let path = consoleTheme.applying(consoleTheme.path, to: file.path)
      let stats = [
        consoleTheme.applying(consoleTheme.muted, to: "("),
        consoleTheme.applying(consoleTheme.additions, to: "+\(file.additions)"),
        consoleTheme.applying(consoleTheme.muted, to: " / "),
        consoleTheme.applying(consoleTheme.deletions, to: "-\(file.deletions)"),
        consoleTheme.applying(consoleTheme.muted, to: ")"),
      ].joined()
      let location = consoleTheme.applying(consoleTheme.metadata, to: "[\(file.location)]")
      logger.info("\(bullet)\(path) \(stats) \(location)")
    }
  }

  private func logPromptDiagnostics(_ diagnostics: PromptDiagnostics) {
    let lineUsage = "\(diagnostics.estimatedLineCount)/\(diagnostics.lineBudget)"
    let highlightedLines = consoleTheme.applying(consoleTheme.emphasis, to: lineUsage)
    let fileUsage = "\(diagnostics.displayedFiles)/\(diagnostics.totalFiles)"
    let highlightedFiles = consoleTheme.applying(consoleTheme.emphasis, to: fileUsage)

    var summaryComponents: [String] = []
    summaryComponents.append("lines \(highlightedLines)")
    summaryComponents.append("files \(highlightedFiles)")
    if diagnostics.compactionApplied {
      summaryComponents.append(consoleTheme.applying(consoleTheme.muted, to: "compacted"))
    }

    logger.info("Prompt budget: \(summaryComponents.joined(separator: ", "))")

    let tokenUsage = diagnostics.actualTotalTokenCount ?? diagnostics.estimatedTokenCount
    let tokenLabel = diagnostics.actualTotalTokenCount == nil ? "Estimated tokens" : "Tokens used"
    let tokenUsageText = consoleTheme.applying(
      consoleTheme.emphasis,
      to: "\(tokenUsage)/\(diagnostics.estimatedTokenLimit)"
    )
    logger.info("\(tokenLabel): \(tokenUsageText)")

    if let promptTokens = diagnostics.actualPromptTokenCount,
      let outputTokens = diagnostics.actualOutputTokenCount
    {
      logger.info("Token breakdown: prompt \(promptTokens), output \(outputTokens)")
    }

    let warningThreshold = Int(Double(diagnostics.estimatedTokenLimit) * 0.9)
    if warningThreshold > 0 && tokenUsage >= warningThreshold {
      logger.warning(
        "Prompt is approaching the \(diagnostics.estimatedTokenLimit)-token window; consider trimming context if generation fails."
      )
    }

    if diagnostics.userContextLineCount > 0 {
      logger.info("User context added \(diagnostics.userContextLineCount) line(s) to the prompt.")
    }

    if diagnostics.snippetFilesTruncated > 0 {
      logger.info(
        "Truncated \(diagnostics.snippetFilesTruncated) snippet(s) to \(diagnostics.snippetLineLimit) line(s)."
      )
    }

    if diagnostics.generatedFilesOmitted > 0 {
      logger.info(
        "Omitted \(diagnostics.generatedFilesOmitted) generated file(s) per .gitattributes."
      )
    }

    if diagnostics.remainderCount > 0 {
      var remainderSummary = "Remaining \(diagnostics.remainderCount) file(s) contribute +\(diagnostics.remainderAdditions) / -\(diagnostics.remainderDeletions)"
      if diagnostics.remainderGeneratedCount > 0 {
        remainderSummary += " (\(diagnostics.remainderGeneratedCount) generated)"
      }
      logger.info(remainderSummary + ".")

      if !diagnostics.remainderHintFiles.isEmpty {
        let sample = diagnostics.remainderHintFiles.prefix(3).map { $0.path }
        if !sample.isEmpty {
          logger.info("Example paths not shown in prompt: \(sample.joined(separator: ", ")).")
        }
      }
    }
  }

  private func stageChanges(for status: GitStatus) async throws {
    let pending = status.unstaged + status.untracked
    guard !pending.isEmpty else { return }

    var paths: Set<String> = []
    for change in pending {
      paths.insert(change.path)
      if let old = change.oldPath {
        paths.insert(old)
      }
    }

    try await gitClient.stage(paths: Array(paths).sorted())
  }
}
