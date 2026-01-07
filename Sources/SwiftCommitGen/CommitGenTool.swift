import Foundation
import Noora

/// Coordinates the end-to-end flow for generating, reviewing, and optionally
/// applying an AI-assisted commit message.
struct CommitGenTool {
  private let options: CommitGenOptions
  private let gitClient: GitClient
  private let summarizer: DiffSummarizer
  private let promptBuilder: PromptBuilder
  private let llmClient: LLMClient
  private let renderer: Renderer
  private let logger: CommitGenLogger
  private let consoleTheme: ConsoleTheme
  private let noora: Noorable

  /// Creates a tool instance with configurable collaborators for easier testing.
  init(
    options: CommitGenOptions,
    gitClient: GitClient = SystemGitClient(),
    summarizer: DiffSummarizer? = nil,
    promptBuilder: PromptBuilder? = nil,
    llmClient: LLMClient = FoundationModelsClient(),
    renderer: Renderer = ConsoleRenderer(),
    logger: CommitGenLogger? = nil,
    noora: Noorable? = nil
  ) {
    self.options = options
    self.gitClient = gitClient

    if let summarizer {
      self.summarizer = summarizer
    } else {
      let perFileMode = options.generationMode == .perFile
      let maxLines = perFileMode ? 200 : 80
      let maxFullLines = perFileMode ? 400 : 200
      self.summarizer = DefaultDiffSummarizer(
        gitClient: gitClient,
        maxLinesPerFile: maxLines,
        maxFullLinesPerFile: maxFullLines
      )
    }

    if let promptBuilder {
      self.promptBuilder = promptBuilder
    } else if options.generationMode == .perFile {
      self.promptBuilder = DefaultPromptBuilder(
        maxFiles: 1,
        maxSnippetLines: 200,
        maxPromptLineEstimate: 800,
        minFiles: 1,
        minSnippetLines: 0,
        snippetReductionStep: 10,
        hintThreshold: 0,
        mediumFileThreshold: Int.max,
        highFileThreshold: Int.max,
        mediumSnippetLimit: 200,
        lowSnippetLimit: 200
      )
    } else {
      self.promptBuilder = DefaultPromptBuilder()
    }
    self.llmClient = llmClient
    self.renderer = renderer
    self.logger = logger ?? CommitGenLogger(isVerbose: options.isVerbose, isQuiet: options.isQuiet)
    self.consoleTheme = self.logger.consoleTheme
    self.noora = noora ?? Noora()
  }

  /// Executes the commit generation pipeline from Git inspection to
  /// interactive review and optional commit application.
  func run() async throws {
    let repoRoot = try await gitClient.repositoryRoot()
    logger.info("Repository root: \(repoRoot.path)")

    var status = try await gitClient.status()

    if options.stageAllBeforeGenerating {
      let pendingBeforeStage = status.unstaged.count + status.untracked.count
      if pendingBeforeStage > 0 {
        logger.notice("Staging \(pendingBeforeStage) pending change(s) due to --stage flag.")
      } else {
        logger.notice("--stage flag set; staging tracked and untracked files (nothing pending).")
      }
      try await gitClient.stageAll()
      status = try await gitClient.status()
    }

    if options.autoStageIfNoStaged && status.staged.isEmpty {
      let pendingBeforeAutoStage = status.unstaged.count + status.untracked.count
      if pendingBeforeAutoStage > 0 {
        logger.notice(
          "No staged changes detected; auto-staging \(pendingBeforeAutoStage) pending change(s) per configuration."
        )
      } else {
        logger.notice(
          "No staged changes detected; auto-stage configuration will attempt to stage tracked and untracked files."
        )
      }
      try await gitClient.stageAll()
      status = try await gitClient.status()
    }

    let stagedChanges = status.staged
    let ignoredPending = status.unstaged.count + status.untracked.count

    if stagedChanges.isEmpty {
      if ignoredPending > 0 {
        logger.warning(
          "Found \(ignoredPending) change(s) that are not staged; they are ignored. Stage them manually or re-run with --stage."
        )
      }
      throw CommitGenError.cleanWorkingTree
    }

    logger.notice("Detected \(stagedChanges.count) staged change(s).")

    if ignoredPending > 0 {
      logger.warning(
        "Ignoring \(ignoredPending) unstaged/untracked change(s). Stage them manually or re-run with --stage to include them."
      )
    }

    let stagedStatus = GitStatus(staged: stagedChanges, unstaged: [], untracked: [])
    let summary = try await summarizer.summarize(
      status: stagedStatus,
      diffOptions: options.diffOptions
    )
    logger.notice(
      "Summary: \(summary.fileCount) file(s), +\(summary.totalAdditions) / -\(summary.totalDeletions)"
    )

    let branchName = (try? await gitClient.currentBranch()) ?? "HEAD"
    let repoName = repositoryName(from: repoRoot)
    let metadata = PromptMetadata(
      repositoryName: repoName,
      branchName: branchName,
      style: options.promptStyle,
      includeUnstagedChanges: false
    )

    if options.outputFormat == .text {
      renderReviewSummary(summary)
    }

    let outcome: GenerationOutcome
    switch options.generationMode {
    case .perFile:
      logger.notice(
        "Single-file analysis enabled; generating individual drafts for each staged file."
      )
      let perFileBatches = makeSingleFileBatches(from: summary)
      outcome = try await generateBatchedDraft(
        batches: perFileBatches,
        metadata: metadata,
        fullSummary: summary
      )
    case .automatic:
      // Group semantically related files together (source + tests, same directory)
      let grouper = SemanticFileGrouper()
      let fileGroups = grouper.groupFiles(summary.files)

      let planner = PromptBatchPlanner()
      let batches = planner.planBatches(for: summary, groups: fileGroups)
      let useBatching = shouldUseBatching(for: batches)

      if useBatching {
        outcome = try await generateBatchedDraft(
          batches: batches,
          metadata: metadata,
          fullSummary: summary
        )
      } else {
        outcome = try await generateSingleDraft(summary: summary, metadata: metadata)
      }
    }

    var draft = outcome.draft
    renderer.render(draft, format: options.outputFormat, report: outcome.report)

    if let report = outcome.report, report.mode == .batched {
      for info in report.batches {
        logger.debug {
          let tokenUsage =
            info.promptDiagnostics.actualTotalTokenCount
            ?? info.promptDiagnostics.estimatedTokenCount
          let subjectPreview = info.draft.subject.isEmpty ? "(empty)" : info.draft.subject
          let samplePaths = info.filePaths.prefix(3)
          let pathPreview: String
          if samplePaths.isEmpty {
            pathPreview = "no files tracked"
          } else if samplePaths.count == info.fileCount {
            pathPreview = samplePaths.joined(separator: ", ")
          } else {
            pathPreview =
              samplePaths.joined(separator: ", ") + "+\(info.fileCount - samplePaths.count) more"
          }
          return
            "Batch \(info.index + 1): \(info.fileCount) file(s), ~\(tokenUsage) tokens, subject: \(subjectPreview). Files: \(pathPreview)."
        }
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
        logPromptDiagnostics(package.diagnostics)
        let regeneration = try await noora.progressStep(
          message: "Regenerating commit message…",
          successMessage: "Commit message regenerated",
          errorMessage: "Regeneration failed",
          showSpinner: true
        ) { _ in
          try await llmClient.generateCommitDraft(from: package)
        }
        logPromptDiagnostics(regeneration.diagnostics)
        return regeneration.draft
      }
    ) {
      draft = reviewedDraft
      try await handleAcceptedDraft(draft)
    } else {
      noora.warning(.alert("Commit generation aborted", takeaway: "No changes were committed"))
    }
  }

  private func repositoryName(from url: URL) -> String {
    let candidate = url.lastPathComponent
    return candidate.isEmpty ? url.path : candidate
  }

  /// Actions available when reviewing a generated draft.
  private enum ReviewAction: String, CaseIterable, CustomStringConvertible {
    case accept = "Accept and commit"
    case edit = "Edit in $EDITOR"
    case regenerate = "Regenerate"
    case regenerateWithContext = "Regenerate with context"
    case abort = "Abort"

    var description: String { rawValue }
  }

  /// Presents the interactive review loop and returns the accepted draft, if any.
  private func reviewDraft(
    initialDraft: CommitDraft,
    regenerate: @escaping (_ additionalContext: String?) async throws -> CommitDraft
  ) async throws -> CommitDraft? {
    var currentDraft = initialDraft

    reviewLoop: while true {
      let action: ReviewAction = noora.singleChoicePrompt(
        title: "Review Draft",
        question: "What would you like to do?",
        description: "Use arrow keys to select, Enter to confirm"
      )

      switch action {
      case .accept:
        return currentDraft
      case .edit:
        if let updated = try editDraft(currentDraft) {
          currentDraft = updated
          renderer.render(currentDraft, format: .text, report: nil)
        }
      case .regenerate:
        currentDraft = try await regenerate(nil)
        renderer.render(currentDraft, format: .text, report: nil)
      case .regenerateWithContext:
        guard let additionalContext = promptForAdditionalContext() else {
          logger.warning("No additional context provided; keeping previous draft.")
          continue
        }
        currentDraft = try await regenerate(additionalContext)
        renderer.render(currentDraft, format: .text, report: nil)
      case .abort:
        break reviewLoop
      }
    }

    return nil
  }

  /// Captures multiline user context for regeneration until a blank line or EOF.
  private func promptForAdditionalContext() -> String? {
    logger.info(
      "Enter additional context for the next draft (blank line to finish, Ctrl+D to cancel):"
    )

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

  /// Opens the current draft in `$EDITOR` and returns the modified version when available.
  private func editDraft(_ draft: CommitDraft) throws -> CommitDraft? {
    let environment = ProcessInfo.processInfo.environment
    guard let editor = environment["EDITOR"], !editor.isEmpty else {
      logger.warning("$EDITOR is not set; skipping edit request.")
      return nil
    }

    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "scg-\(UUID().uuidString).txt"
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

  /// Applies the accepted draft or prints follow-up instructions based on options.
  private func handleAcceptedDraft(
    _ draft: CommitDraft
  ) async throws {
    logger.notice("Commit draft accepted.")

    guard options.autoCommit else {
      logger.warning(
        "Auto-commit disabled; run `git commit` manually or re-run with --commit to apply the draft automatically."
      )
      return
    }

    try await gitClient.commit(message: draft.commitMessage)
    noora.success(.alert("Commit created successfully", takeaways: [
      "Subject: \(draft.subject)"
    ]))
  }

  /// Emits a human-readable summary of the staged files before prompt generation.
  private func renderReviewSummary(_ summary: ChangeSummary) {
    guard !summary.files.isEmpty else { return }
    logger.notice("Reviewing \(summary.fileCount) file(s):")
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
      logger.notice("\(bullet)\(path) \(stats) \(location)")
    }
  }

  /// Logs prompt budgeting diagnostics when verbose logging is enabled.
  private func logPromptDiagnostics(_ diagnostics: PromptDiagnostics) {
    guard logger.isVerboseEnabled else { return }
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

    logger.debug("Prompt budget: \(summaryComponents.joined(separator: ", "))")

    let tokenUsage = diagnostics.actualTotalTokenCount ?? diagnostics.estimatedTokenCount
    let tokenLabel = diagnostics.actualTotalTokenCount == nil ? "Estimated tokens" : "Tokens used"
    let tokenUsageText = consoleTheme.applying(
      consoleTheme.emphasis,
      to: "\(tokenUsage)/\(diagnostics.estimatedTokenLimit)"
    )
    logger.debug("\(tokenLabel): \(tokenUsageText)")

    if let promptTokens = diagnostics.actualPromptTokenCount,
      let outputTokens = diagnostics.actualOutputTokenCount
    {
      logger.debug("Token breakdown: prompt \(promptTokens), output \(outputTokens)")
    }

    let warningThreshold = Int(Double(diagnostics.estimatedTokenLimit) * 0.9)
    if warningThreshold > 0 && tokenUsage >= warningThreshold {
      logger.debug(
        "Prompt is approaching the \(diagnostics.estimatedTokenLimit)-token window; consider trimming context if generation fails."
      )
    }

    if diagnostics.userContextLineCount > 0 {
      logger.debug("User context added \(diagnostics.userContextLineCount) line(s) to the prompt.")
    }

    if diagnostics.snippetFilesTruncated > 0 {
      logger.debug(
        "Truncated \(diagnostics.snippetFilesTruncated) snippet(s) to \(diagnostics.snippetLineLimit) line(s)."
      )
    }

    if diagnostics.generatedFilesOmitted > 0 {
      logger.debug(
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
      logger.debug("Top prompt contributors: \(topContributors.joined(separator: "; ")).")
    }

    if diagnostics.remainderCount > 0 {
      var remainderSummary =
        "Remaining \(diagnostics.remainderCount) file(s) contribute +\(diagnostics.remainderAdditions) / -\(diagnostics.remainderDeletions)"
      if diagnostics.remainderGeneratedCount > 0 {
        remainderSummary += " (\(diagnostics.remainderGeneratedCount) generated)"
      }
      logger.debug(remainderSummary + ".")

      if !diagnostics.remainderHintFiles.isEmpty {
        let sample = diagnostics.remainderHintFiles.prefix(3).map { $0.path }
        if !sample.isEmpty {
          logger.debug("Example paths not shown in prompt: \(sample.joined(separator: ", ")).")
        }
      }
    }
  }
}

extension CommitGenTool {
  /// Captures the artifacts produced during a generation request.
  fileprivate struct GenerationOutcome {
    var draft: CommitDraft
    var promptPackage: PromptPackage
    var diagnostics: PromptDiagnostics
    var report: GenerationReport?
  }

  /// Determines whether multi-batch prompting is required for the change set.
  fileprivate func shouldUseBatching(for batches: [PromptBatch]) -> Bool {
    guard !batches.isEmpty else { return false }
    if batches.count > 1 {
      return true
    }
    return batches.first?.exceedsBudget ?? false
  }

  /// Builds single-file prompt batches when the per-file mode is active.
  private func makeSingleFileBatches(from summary: ChangeSummary) -> [PromptBatch] {
    guard !summary.files.isEmpty else { return [] }

    let tokenBudget = 4_096
    let headroomRatio = 0.15
    let targetBudget = max(1, Int(Double(tokenBudget) * (1.0 - headroomRatio)))

    return summary.files.map { file in
      var fullFile = file
      fullFile.applySnippetMode(.full)

      let lines = fullFile.promptLines()
      let characterCount = lines.reduce(0) { partial, line in
        partial + line.count + 1
      }
      let tokenEstimate = PromptDiagnostics.tokenEstimate(forCharacterCount: characterCount)
      let usage = PromptDiagnostics.FileUsage(
        path: fullFile.path,
        kind: fullFile.kind.description,
        location: fullFile.location,
        lineCount: lines.count,
        tokenEstimate: tokenEstimate,
        isGenerated: fullFile.isGenerated,
        isBinary: fullFile.isBinary,
        snippetTruncated: fullFile.snippetTruncated,
        usedFullSnippet: fullFile.snippetMode == .full
      )

      return PromptBatch(
        files: [fullFile],
        tokenEstimate: tokenEstimate,
        lineEstimate: lines.count,
        fileUsages: [usage],
        exceedsBudget: tokenEstimate > targetBudget
      )
    }
  }

  /// Generates a draft using a single prompt for the entire change summary.
  fileprivate func generateSingleDraft(
    summary: ChangeSummary,
    metadata: PromptMetadata
  ) async throws -> GenerationOutcome {
    let promptPackage = promptBuilder.makePrompt(summary: summary, metadata: metadata)
    logPromptDiagnostics(promptPackage.diagnostics)

    let generation = try await noora.progressStep(
      message: "Generating commit message…",
      successMessage: "Commit message generated",
      errorMessage: "Generation failed",
      showSpinner: true
    ) { _ in
      try await llmClient.generateCommitDraft(from: promptPackage)
    }
    logPromptDiagnostics(generation.diagnostics)

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

  /// Generates partial drafts for each batch and combines them into a unified message.
  fileprivate func generateBatchedDraft(
    batches: [PromptBatch],
    metadata: PromptMetadata,
    fullSummary: ChangeSummary
  ) async throws -> GenerationOutcome {
    logger.notice(
      "Large change set spans \(fullSummary.fileCount) file(s); splitting into \(batches.count) prompt batch(es)."
    )

    // Two-pass analysis: For large changesets, first get a high-level overview
    // to provide context to each batch. This helps maintain coherence across batches.
    let useTwoPass = fullSummary.fileCount > 15 || batches.count > 3
    var overviewContext: String?

    if useTwoPass {
      logger.info("Using two-pass analysis for large changeset...")

      let overviewBuilder = OverviewPromptBuilder()
      let overviewPrompt = overviewBuilder.makePrompt(summary: fullSummary, metadata: metadata)
      logPromptDiagnostics(overviewPrompt.diagnostics)

      do {
        let overviewResult = try await llmClient.generateOverview(from: overviewPrompt)
        logPromptDiagnostics(overviewResult.diagnostics)

        // Build minimal context from overview - only category and key files.
        // Explicitly avoid passing the summary to batches, as the on-device LLM
        // tends to copy it verbatim instead of analyzing the actual diffs.
        var contextParts: [String] = []
        let category = overviewResult.overview.category
        if !category.isEmpty {
          contextParts.append("Overall change type: \(category)")
        }
        if !overviewResult.overview.keyFiles.isEmpty {
          contextParts.append(
            "Key files in full changeset: \(overviewResult.overview.keyFiles.prefix(5).joined(separator: ", "))")
        }
        overviewContext = contextParts.isEmpty ? nil : contextParts.joined(separator: ". ")

        logger.debug("Overview summary: \(overviewResult.overview.summary)")
        logger.debug("Overview category: \(overviewResult.overview.category)")
      } catch {
        // If overview generation fails, continue without it
        logger.warning("Overview generation failed, proceeding without high-level context: \(error)")
      }
    }

    var partialDrafts: [BatchPartialDraft] = []

    for (index, batch) in batches.enumerated() {
      let batchNumber = index + 1
      logger.info(
        "Batch \(batchNumber)/\(batches.count): generating draft for \(batch.files.count) file(s) (estimated ~\(batch.tokenEstimate) tokens)."
      )

      let batchSummary = ChangeSummary(files: batch.files)
      var batchPackage = promptBuilder.makePrompt(summary: batchSummary, metadata: metadata)

      let fileList = batch.files.prefix(10).map { "- \($0.path)" }.joined(separator: "\n")
      var contextLines: [String] = []

      contextLines.append(
        "Batch \(batchNumber) of \(batches.count). Analyze the diff content above and describe the specific code changes."
      )

      // Include minimal overview context (category and key files only)
      if let overview = overviewContext {
        contextLines.append(overview)
      }
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

      logPromptDiagnostics(batchPackage.diagnostics)

      let generation = try await noora.progressStep(
        message: "Processing batch \(batchNumber)/\(batches.count)…",
        successMessage: "Batch \(batchNumber) complete",
        errorMessage: "Batch \(batchNumber) failed",
        showSpinner: true
      ) { _ in
        try await llmClient.generateCommitDraft(from: batchPackage)
      }
      logPromptDiagnostics(generation.diagnostics)
      logger.debug("Batch \(batchNumber) partial subject: \(generation.draft.subject)")

      let draftMessage = generation.draft.commitMessage
      if draftMessage.isEmpty {
        logger.debug("Batch \(batchNumber) draft content: (empty draft)")
      } else {
        logger.debug(
          """
          Batch \(batchNumber) draft content:
          \(draftMessage)
          """
        )
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
      metadata: metadata,
      partials: sortedPartials
    )
    logPromptDiagnostics(combinationPrompt.diagnostics)

    let combinationGeneration = try await noora.progressStep(
      message: "Combining \(partialDrafts.count) partial drafts…",
      successMessage: "Commit message generated",
      errorMessage: "Combination failed",
      showSpinner: true
    ) { _ in
      try await llmClient.generateCommitDraft(from: combinationPrompt)
    }
    logPromptDiagnostics(combinationGeneration.diagnostics)

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
