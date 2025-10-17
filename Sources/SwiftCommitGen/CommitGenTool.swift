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

    if options.outputFormat == .text {
      renderReviewSummary(summary)
    }

    let planner = PromptBatchPlanner()
    let batches = planner.planBatches(for: summary)
    let useBatching = shouldUseBatching(for: batches)

    let outcome: GenerationOutcome
    if useBatching {
      outcome = try await generateBatchedDraft(
        batches: batches,
        metadata: metadata,
        fullSummary: summary
      )
    } else {
      outcome = try await generateSingleDraft(summary: summary, metadata: metadata)
    }

    var draft = outcome.draft
    renderer.render(draft, format: options.outputFormat, report: outcome.report)

    if options.isVerbose, let report = outcome.report, report.mode == .batched {
      for info in report.batches {
        let tokenUsage =
          info.promptDiagnostics.actualTotalTokenCount
          ?? info.promptDiagnostics.estimatedTokenCount
        let subjectPreview =
          info.draft.subject.isEmpty
          ? "(empty)"
          : info.draft.subject
        let samplePaths = info.filePaths.prefix(3)
        let pathPreview: String
        if samplePaths.isEmpty {
          pathPreview = "no files tracked"
        } else if samplePaths.count == info.fileCount {
          pathPreview = samplePaths.joined(separator: ", ")
        } else {
          pathPreview =
            samplePaths.joined(separator: ", ")
            + " +\(info.fileCount - samplePaths.count) more"
        }
        logger.info(
          "Batch \(info.index + 1): \(info.fileCount) file(s), ~\(tokenUsage) tokens, subject: \(subjectPreview). Files: \(pathPreview)."
        )
      }
    }

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
          additionalContext.map { outcome.promptPackage.appendingUserContext($0) }
          ?? outcome.promptPackage
        if options.isVerbose {
          logPromptDiagnostics(package.diagnostics)
        }
        let regeneration = try await llmClient.generateCommitDraft(from: package)
        if options.isVerbose {
          logPromptDiagnostics(regeneration.diagnostics)
        }
        return regeneration.draft
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
      "staged"
    case .unstaged:
      "unstaged"
    case .all:
      "staged + unstaged"
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
          renderer.render(currentDraft, format: .text, report: nil)
        }
      case "r", "regen", "regenerate":
        logger.info("Requesting a new commit draft from the on-device language model…")
        currentDraft = try await regenerate(nil)
        renderer.render(currentDraft, format: .text, report: nil)
      case "c", "context":
        guard let additionalContext = promptForAdditionalContext() else {
          logger.warning("No additional context provided; keeping previous draft.")
          continue
        }
        logger.info("Requesting a new commit draft with user context…")
        currentDraft = try await regenerate(additionalContext)
        renderer.render(currentDraft, format: .text, report: nil)
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

    if !diagnostics.fileUsages.isEmpty {
      let heaviest = diagnostics.fileUsages.sorted { lhs, rhs in
        lhs.tokenEstimate > rhs.tokenEstimate
      }
      let topContributors = heaviest.prefix(3).map { usage -> String in
        let path = consoleTheme.applying(consoleTheme.path, to: usage.path)
        let tokenText = consoleTheme.applying(consoleTheme.emphasis, to: "\(usage.tokenEstimate)")
        let lineText = consoleTheme.applying(consoleTheme.muted, to: "\(usage.lineCount) ln")
        var descriptors: [String] = []
        if usage.isGenerated {
          descriptors.append("generated")
        }
        if usage.isBinary {
          descriptors.append("binary")
        }
        if usage.snippetTruncated {
          descriptors.append("trimmed")
        }
        if usage.usedFullSnippet {
          descriptors.append("full snippet")
        }
        let descriptorText: String
        if descriptors.isEmpty {
          descriptorText = ""
        } else {
          let joined = descriptors.joined(separator: ", ")
          descriptorText = " " + consoleTheme.applying(consoleTheme.muted, to: "[\(joined)]")
        }
        return "\(path) (\(tokenText) tok, \(lineText))\(descriptorText)"
      }
      logger.info("Top prompt contributors: \(topContributors.joined(separator: "; ")).")
    }

    if diagnostics.remainderCount > 0 {
      var remainderSummary =
        "Remaining \(diagnostics.remainderCount) file(s) contribute +\(diagnostics.remainderAdditions) / -\(diagnostics.remainderDeletions)"
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

extension CommitGenTool {
  fileprivate struct GenerationOutcome {
    var draft: CommitDraft
    var promptPackage: PromptPackage
    var diagnostics: PromptDiagnostics
    var report: GenerationReport?
  }

  fileprivate func shouldUseBatching(for batches: [PromptBatch]) -> Bool {
    guard !batches.isEmpty else { return false }
    if batches.count > 1 {
      return true
    }
    return batches.first?.exceedsBudget ?? false
  }

  fileprivate func generateSingleDraft(
    summary: ChangeSummary, metadata: PromptMetadata
  ) async throws -> GenerationOutcome {
    let promptPackage = promptBuilder.makePrompt(summary: summary, metadata: metadata)
    if options.isVerbose {
      logPromptDiagnostics(promptPackage.diagnostics)
    }

    logger.info("Requesting commit draft from the on-device language model…")
    let generation = try await llmClient.generateCommitDraft(from: promptPackage)
    if options.isVerbose {
      logPromptDiagnostics(generation.diagnostics)
    }

    return GenerationOutcome(
      draft: generation.draft,
      promptPackage: promptPackage,
      diagnostics: generation.diagnostics,
      report: GenerationReport(
        mode: .single,
        finalPromptDiagnostics: generation.diagnostics,
        batches: []
      )
    )
  }

  fileprivate func generateBatchedDraft(
    batches: [PromptBatch],
    metadata: PromptMetadata,
    fullSummary: ChangeSummary
  ) async throws -> GenerationOutcome {
    logger.info(
      "Large change set spans \(fullSummary.fileCount) file(s); splitting into \(batches.count) prompt batch(es)."
    )

    var partialDrafts: [BatchPartialDraft] = []

    for (index, batch) in batches.enumerated() {
      let batchNumber = index + 1
      logger.info(
        "Batch \(batchNumber)/\(batches.count): generating draft for \(batch.files.count) file(s) (estimated ~\(batch.tokenEstimate) tokens)."
      )

      let batchSummary = ChangeSummary(files: batch.files)
      var batchPackage = promptBuilder.makePrompt(summary: batchSummary, metadata: metadata)

      let fileList = batch.files.prefix(10).map { "- \($0.path)" }.joined(separator: "\n")
      var contextLines: [String] = [
        "Batch \(batchNumber) of \(batches.count). Focus exclusively on these files; other batches are handled separately."
      ]
      if !fileList.isEmpty {
        contextLines.append("Files in this batch:")
        contextLines.append(fileList)
      }
      if batch.exceedsBudget {
        contextLines.append(
          "This batch still approaches the token budget; prioritize the most important changes."
        )
      }
      let additionalContext = contextLines.joined(separator: "\n")
      batchPackage = batchPackage.appendingUserContext(additionalContext)

      if options.isVerbose {
        logPromptDiagnostics(batchPackage.diagnostics)
      }

      let generation = try await llmClient.generateCommitDraft(from: batchPackage)
      if options.isVerbose {
        logPromptDiagnostics(generation.diagnostics)
        logger.info("Batch \(batchNumber) partial subject: \(generation.draft.subject)")
      }

      let partial = BatchPartialDraft(
        batchIndex: index,
        files: batch.files,
        draft: generation.draft,
        diagnostics: generation.diagnostics
      )
      partialDrafts.append(partial)
    }

    let sortedPartials = partialDrafts.sorted { $0.batchIndex < $1.batchIndex }
    let batchReports: [GenerationReport.BatchInfo] = sortedPartials.map { partial in
      let batch = batches[partial.batchIndex]
      return GenerationReport.BatchInfo(
        index: partial.batchIndex,
        fileCount: batch.files.count,
        filePaths: batch.files.map { $0.path },
        exceedsBudget: batch.exceedsBudget,
        promptDiagnostics: partial.diagnostics,
        draft: partial.draft
      )
    }

    let combinationBuilder = BatchCombinationPromptBuilder()
    let combinationPrompt = combinationBuilder.makePrompt(
      metadata: metadata, partials: sortedPartials)
    if options.isVerbose {
      logPromptDiagnostics(combinationPrompt.diagnostics)
    }

    logger.info("Combining \(partialDrafts.count) partial draft(s) into a unified commit message…")
    let combinationGeneration = try await llmClient.generateCommitDraft(from: combinationPrompt)
    if options.isVerbose {
      logPromptDiagnostics(combinationGeneration.diagnostics)
    }

    return GenerationOutcome(
      draft: combinationGeneration.draft,
      promptPackage: combinationPrompt,
      diagnostics: combinationGeneration.diagnostics,
      report: GenerationReport(
        mode: .batched,
        finalPromptDiagnostics: combinationGeneration.diagnostics,
        batches: batchReports
      )
    )
  }
}
