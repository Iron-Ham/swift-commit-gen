import Foundation

/// Represents a slice of files that will be summarized together in a single prompt.
struct PromptBatch: Sendable {
  var files: [ChangeSummary.FileSummary]
  var tokenEstimate: Int
  var lineEstimate: Int
  var fileUsages: [PromptDiagnostics.FileUsage]
  var exceedsBudget: Bool
}

/// Captures the draft and diagnostics generated for a specific batch.
struct BatchPartialDraft: Sendable {
  var batchIndex: Int
  var files: [ChangeSummary.FileSummary]
  var draft: CommitDraft
  var diagnostics: PromptDiagnostics
}

/// Decides how to partition large change sets into prompt-sized batches.
struct PromptBatchPlanner {
  var tokenBudget: Int
  var headroomRatio: Double
  var minimumBatchSize: Int
  private let importanceScorer = FileImportanceScorer()

  init(tokenBudget: Int = 4_096, headroomRatio: Double = 0.15, minimumBatchSize: Int = 1) {
    self.tokenBudget = max(1, tokenBudget)
    self.headroomRatio = max(0, min(headroomRatio, 0.9))
    self.minimumBatchSize = max(1, minimumBatchSize)
  }

  /// Computes prompt batches sized to stay within the configured token budget.
  /// - Parameters:
  ///   - summary: The change summary containing files to batch.
  ///   - groups: Optional pre-computed semantic groups. If provided, files within
  ///             each group will be kept adjacent during batching.
  func planBatches(
    for summary: ChangeSummary,
    groups: [[ChangeSummary.FileSummary]]? = nil
  ) -> [PromptBatch] {
    guard !summary.files.isEmpty else { return [] }

    // Compute importance scores for all files
    let importanceScores = importanceScorer.scoresByPath(summary.files)

    // Use grouped order if provided, otherwise use original file order
    let orderedFiles: [ChangeSummary.FileSummary]
    if let groups = groups {
      orderedFiles = groups.flatMap { $0 }
    } else {
      orderedFiles = summary.files
    }

    let targetBudget = max(1, Int(Double(tokenBudget) * (1.0 - headroomRatio)))
    let contributions = orderedFiles.map { file -> FileContribution in
      let compactFile = file.withSnippetMode(.compact)
      let compactLines = compactFile.promptLines()
      let compactCharCount = compactLines.reduce(0) { partial, line in
        partial + line.count + 1
      }
      let compactTokens = PromptDiagnostics.tokenEstimate(forCharacterCount: compactCharCount)

      let fullFile = file.withSnippetMode(.full)
      let fullLines = fullFile.promptLines()
      let fullCharCount = fullLines.reduce(0) { partial, line in
        partial + line.count + 1
      }
      let fullTokens = PromptDiagnostics.tokenEstimate(forCharacterCount: fullCharCount)
      let canUseFull = fullFile.snippetMode == .full && (fullTokens > 0 || !fullLines.isEmpty)

      return FileContribution(
        compactFile: compactFile,
        fullFile: fullFile,
        compactTokenEstimate: compactTokens,
        fullTokenEstimate: fullTokens,
        compactLineCount: compactLines.count,
        fullLineCount: fullLines.count,
        canUseFull: canUseFull,
        importanceScore: importanceScores[file.path] ?? 0
      )
    }
    // Note: When groups are provided, we preserve their order to keep semantically
    // related files together. Without groups, we sort by token size for packing efficiency.
    let sortedContributions: [FileContribution]
    if groups != nil {
      // Preserve group order - files already in semantic order
      sortedContributions = contributions
    } else {
      // Sort by token size (descending) for efficient packing
      sortedContributions = contributions.sorted { lhs, rhs in
        if lhs.compactTokenEstimate == rhs.compactTokenEstimate {
          return lhs.compactFile.path < rhs.compactFile.path
        }
        return lhs.compactTokenEstimate > rhs.compactTokenEstimate
      }
    }

    var batches: [PromptBatch] = []
    var currentContributions: [FileContribution] = []
    var currentTokenTotal = 0

    func closeCurrentBatch(force: Bool = false) {
      guard !currentContributions.isEmpty else { return }
      let batch = finalizeBatch(
        contributions: currentContributions,
        targetBudget: targetBudget
      )
      batches.append(batch)
      currentContributions.removeAll(keepingCapacity: !force)
      currentTokenTotal = 0
    }

    for contribution in sortedContributions {
      let nextTokenTotal = currentTokenTotal + contribution.compactTokenEstimate

      if !currentContributions.isEmpty && nextTokenTotal > targetBudget {
        closeCurrentBatch()
      }

      currentContributions.append(contribution)
      currentTokenTotal += contribution.compactTokenEstimate

      if contribution.compactTokenEstimate > targetBudget {
        closeCurrentBatch()
      }

      if currentContributions.count >= minimumBatchSize && currentTokenTotal >= targetBudget {
        closeCurrentBatch()
      }
    }

    closeCurrentBatch(force: true)

    return batches
  }

  private struct FileContribution {
    var compactFile: ChangeSummary.FileSummary
    var fullFile: ChangeSummary.FileSummary
    var compactTokenEstimate: Int
    var fullTokenEstimate: Int
    var compactLineCount: Int
    var fullLineCount: Int
    var canUseFull: Bool
    var importanceScore: Int
  }

  private func finalizeBatch(
    contributions: [FileContribution],
    targetBudget: Int
  ) -> PromptBatch {
    var useFull = Array(repeating: false, count: contributions.count)

    for (index, contribution) in contributions.enumerated() where contribution.canUseFull {
      let delta = contribution.fullTokenEstimate - contribution.compactTokenEstimate
      if delta <= 0 {
        useFull[index] = true
      }
    }

    var totalTokens = totalTokens(for: contributions, useFull: useFull)
    var totalLines = totalLines(for: contributions, useFull: useFull)

    // Build candidates with importance scores for prioritized allocation
    var candidates: [(index: Int, delta: Int, importance: Int)] = []
    for (index, contribution) in contributions.enumerated() where contribution.canUseFull {
      let delta = contribution.fullTokenEstimate - contribution.compactTokenEstimate
      if delta > 0 {
        candidates.append((index, delta, contribution.importanceScore))
      }
    }

    // Sort by importance score (descending), then by token delta (ascending) for ties.
    // This ensures more important files get full snippets first, and among equally
    // important files, we prefer those that cost fewer tokens.
    candidates.sort { lhs, rhs in
      if lhs.importance != rhs.importance {
        return lhs.importance > rhs.importance  // Higher importance first
      }
      if lhs.delta != rhs.delta {
        return lhs.delta < rhs.delta  // Lower token cost first
      }
      return lhs.index < rhs.index  // Stable sort by index
    }

    for candidate in candidates where !useFull[candidate.index] {
      let potentialTotal = totalTokens + candidate.delta
      if potentialTotal <= tokenBudget {
        useFull[candidate.index] = true
        totalTokens = potentialTotal
        totalLines +=
          contributions[candidate.index].fullLineCount
          - contributions[candidate.index].compactLineCount
      }
    }

    var files: [ChangeSummary.FileSummary] = []
    var usages: [PromptDiagnostics.FileUsage] = []
    totalTokens = 0
    totalLines = 0

    for (index, contribution) in contributions.enumerated() {
      let file = useFull[index] ? contribution.fullFile : contribution.compactFile
      files.append(file)
      let lines = file.promptLines()
      let characterCount = lines.reduce(0) { partial, line in
        partial + line.count + 1
      }
      let tokenEstimate = PromptDiagnostics.tokenEstimate(forCharacterCount: characterCount)
      totalTokens += tokenEstimate
      totalLines += lines.count
      usages.append(
        PromptDiagnostics.FileUsage(
          path: file.path,
          kind: file.kind.description,
          location: file.location,
          lineCount: lines.count,
          tokenEstimate: tokenEstimate,
          isGenerated: file.isGenerated,
          isBinary: file.isBinary,
          snippetTruncated: file.snippetTruncated,
          usedFullSnippet: file.snippetMode == .full
        )
      )
    }

    let exceeds = totalTokens > targetBudget
    return PromptBatch(
      files: files,
      tokenEstimate: totalTokens,
      lineEstimate: totalLines,
      fileUsages: usages,
      exceedsBudget: exceeds
    )
  }

  private func totalTokens(
    for contributions: [FileContribution],
    useFull: [Bool]
  ) -> Int {
    var total = 0
    for (index, contribution) in contributions.enumerated() {
      total += useFull[index] ? contribution.fullTokenEstimate : contribution.compactTokenEstimate
    }
    return total
  }

  private func totalLines(
    for contributions: [FileContribution],
    useFull: [Bool]
  ) -> Int {
    var total = 0
    for (index, contribution) in contributions.enumerated() {
      total += useFull[index] ? contribution.fullLineCount : contribution.compactLineCount
    }
    return total
  }
}
