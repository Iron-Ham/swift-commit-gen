import FoundationModels

/// High-level context that accompanies the diff when constructing model prompts.
struct PromptMetadata: PromptRepresentable {
  var repositoryName: String
  var branchName: String
  var style: CommitGenOptions.PromptStyle
  var includeUnstagedChanges: Bool

  init(
    repositoryName: String,
    branchName: String,
    style: CommitGenOptions.PromptStyle,
    includeUnstagedChanges: Bool,
  ) {
    self.repositoryName = repositoryName
    self.branchName = branchName
    self.style = style
    self.includeUnstagedChanges = includeUnstagedChanges
  }

  var scopeDescription: String {
    includeUnstagedChanges ? "staged + unstaged changes" : "staged changes only"
  }

  var promptRepresentation: Prompt {
    Prompt {
      "Repository: \(repositoryName)"
      "Branch: \(branchName)"
      "Scope: \(scopeDescription)"
      "Style: \(style)"
    }
  }
}

/// Produces the system and user prompts that will be sent to the language model.
protocol PromptBuilder {
  func makePrompt(summary: ChangeSummary, metadata: PromptMetadata) -> PromptPackage
}

/// Tracks prompt budgeting metrics so callers can understand model usage.
struct PromptDiagnostics: Codable, Sendable {
  struct KindCount: Codable, Hashable, Sendable {
    var kind: String
    var count: Int
  }

  struct Hint: Codable, Hashable, Sendable {
    var path: String
    var kind: String
    var location: GitChangeLocation
    var isBinary: Bool
    var isGenerated: Bool
  }

  struct FileUsage: Codable, Hashable, Sendable {
    var path: String
    var kind: String
    var location: GitChangeLocation
    var lineCount: Int
    var tokenEstimate: Int
    var isGenerated: Bool
    var isBinary: Bool
    var snippetTruncated: Bool
    var usedFullSnippet: Bool
  }

  var estimatedLineCount: Int
  var lineBudget: Int
  var userContextLineCount: Int = 0

  var estimatedTokenCount: Int
  var estimatedTokenLimit: Int
  var actualPromptTokenCount: Int?
  var actualOutputTokenCount: Int?
  var actualTotalTokenCount: Int?

  var totalFiles: Int
  var displayedFiles: Int
  var configuredFileLimit: Int

  var snippetLineLimit: Int
  var configuredSnippetLineLimit: Int
  var snippetFilesTruncated: Int

  var compactionApplied: Bool

  var generatedFilesTotal: Int
  var generatedFilesDisplayed: Int
  var generatedFilesOmitted: Int {
    max(0, generatedFilesTotal - generatedFilesDisplayed)
  }

  var fileUsages: [FileUsage]

  var remainderCount: Int
  var remainderAdditions: Int
  var remainderDeletions: Int
  var remainderGeneratedCount: Int
  var remainderKindBreakdown: [KindCount]
  var remainderHintLimit: Int
  var remainderHintFiles: [Hint]
  var remainderNonGeneratedCount: Int

  mutating func recordAdditionalUserContext(lineCount: Int, characterCount: Int) {
    guard lineCount > 0 else { return }
    userContextLineCount += lineCount
    estimatedLineCount += lineCount
    estimatedTokenCount += Self.tokenEstimate(forCharacterCount: characterCount)
  }

  mutating func recordActualTokenUsage(
    promptTokens: Int?,
    outputTokens: Int?,
    totalTokens: Int?
  ) {
    actualPromptTokenCount = promptTokens
    actualOutputTokenCount = outputTokens
    actualTotalTokenCount = totalTokens
  }

  static func tokenEstimate(forCharacterCount count: Int) -> Int {
    guard count > 0 else { return 0 }
    let approximateCharactersPerToken = 4
    return max(1, (count + (approximateCharactersPerToken - 1)) / approximateCharactersPerToken)
  }
}

/// Bundles the full prompt payload and derived diagnostics for a generation request.
struct PromptPackage {
  var systemPrompt: Instructions
  var userPrompt: Prompt
  var diagnostics: PromptDiagnostics

  func appendingUserContext(_ context: String) -> PromptPackage {
    let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return self }

    let contextLineCount = trimmed.split(
      omittingEmptySubsequences: false,
      whereSeparator: \.isNewline
    ).count
    let additionalLines = contextLineCount + 2  // blank separator + heading

    let augmentedUserPrompt = Prompt {
      userPrompt
      ""
      "Additional context from user:"
      trimmed
    }

    var updatedDiagnostics = diagnostics
    let additionalCharacters =
      trimmed.count
      + "Additional context from user:".count
    let newlineCharacters = additionalLines  // account for line breaks
    updatedDiagnostics.recordAdditionalUserContext(
      lineCount: additionalLines,
      characterCount: additionalCharacters + newlineCharacters
    )

    return PromptPackage(
      systemPrompt: systemPrompt,
      userPrompt: augmentedUserPrompt,
      diagnostics: updatedDiagnostics
    )
  }
}

/// Default prompt builder that balances snippet detail against token constraints.
struct DefaultPromptBuilder: PromptBuilder {
  private let maxFiles: Int
  private let maxSnippetLines: Int
  private let maxPromptLineEstimate: Int
  private let minFiles: Int
  private let minSnippetLines: Int
  private let snippetReductionStep: Int
  private let hintThreshold: Int
  private let mediumFileThreshold: Int
  private let highFileThreshold: Int
  private let mediumSnippetLimit: Int
  private let lowSnippetLimit: Int

  init(
    maxFiles: Int = 12,
    maxSnippetLines: Int = 50,
    maxPromptLineEstimate: Int = 600,
    minFiles: Int = 3,
    minSnippetLines: Int = 6,
    snippetReductionStep: Int = 4,
    hintThreshold: Int = 10,
    mediumFileThreshold: Int = 20,
    highFileThreshold: Int = 40,
    mediumSnippetLimit: Int = 15,
    lowSnippetLimit: Int = 8
  ) {
    self.maxFiles = maxFiles
    self.maxSnippetLines = maxSnippetLines
    self.maxPromptLineEstimate = maxPromptLineEstimate
    self.minFiles = minFiles
    self.minSnippetLines = minSnippetLines
    self.snippetReductionStep = max(1, snippetReductionStep)
    self.hintThreshold = hintThreshold
    self.mediumFileThreshold = mediumFileThreshold
    self.highFileThreshold = highFileThreshold
    self.mediumSnippetLimit = mediumSnippetLimit
    self.lowSnippetLimit = lowSnippetLimit
  }

  func makePrompt(summary: ChangeSummary, metadata: PromptMetadata) -> PromptPackage {
    let system = buildSystemPrompt(style: metadata.style)

    var fileLimit = min(maxFiles, summary.fileCount)
    var snippetLimit = adjustedSnippetLimit(
      totalFiles: summary.fileCount,
      configuredLimit: maxSnippetLines
    )

    var displaySummary = trimSummary(summary, fileLimit: fileLimit, snippetLimit: snippetLimit)
    var remainderContext = makeRemainderContext(
      fullSummary: summary,
      displaySummary: displaySummary,
      hintLimit: hintThreshold
    )
    var isCompacted = displaySummary.fileCount < summary.fileCount || snippetLimit < maxSnippetLines

    var user = buildUserPrompt(
      displaySummary: displaySummary,
      fullSummary: summary,
      metadata: metadata,
      isCompacted: isCompacted,
      remainder: remainderContext
    )

    var estimate = estimatedLineCount(
      displaySummary: displaySummary,
      fullSummary: summary,
      includesCompactionNote: isCompacted,
      remainder: remainderContext
    )

    while estimate > maxPromptLineEstimate {
      if snippetLimit > minSnippetLines {
        snippetLimit = max(minSnippetLines, snippetLimit - snippetReductionStep)
      } else if fileLimit > minFiles {
        fileLimit = max(minFiles, fileLimit - 1)
      } else {
        break
      }

      displaySummary = trimSummary(summary, fileLimit: fileLimit, snippetLimit: snippetLimit)
      remainderContext = makeRemainderContext(
        fullSummary: summary,
        displaySummary: displaySummary,
        hintLimit: hintThreshold
      )
      isCompacted = displaySummary.fileCount < summary.fileCount || snippetLimit < maxSnippetLines

      user = buildUserPrompt(
        displaySummary: displaySummary,
        fullSummary: summary,
        metadata: metadata,
        isCompacted: isCompacted,
        remainder: remainderContext
      )

      estimate = estimatedLineCount(
        displaySummary: displaySummary,
        fullSummary: summary,
        includesCompactionNote: isCompacted,
        remainder: remainderContext
      )
    }

    let finalCompaction =
      displaySummary.fileCount < summary.fileCount || snippetLimit < maxSnippetLines

    let diagnostics = makeDiagnostics(
      metadata: metadata,
      fullSummary: summary,
      displaySummary: displaySummary,
      snippetLimit: snippetLimit,
      isCompacted: finalCompaction,
      remainder: remainderContext,
      estimatedLines: estimate,
      lineBudget: maxPromptLineEstimate,
      configuredFileLimit: maxFiles,
      configuredSnippetLimit: maxSnippetLines,
      hintLimit: hintThreshold
    )

    return PromptPackage(systemPrompt: system, userPrompt: user, diagnostics: diagnostics)
  }

  private func buildSystemPrompt(style: CommitGenOptions.PromptStyle) -> Instructions {
    Instructions {
      """
      Write a git commit message for the code changes shown.

      Subject: max 50 chars, imperative mood ("Add X" not "Added X"), describe WHAT changed.
      Body: optional, explain WHY if helpful.

      Read the diff carefully. Lines with + are additions, - are deletions.
      """
      ""
      style.styleGuidance
    }
  }

  private func adjustedSnippetLimit(totalFiles: Int, configuredLimit: Int) -> Int {
    var limit = configuredLimit

    if totalFiles >= highFileThreshold {
      limit = min(limit, lowSnippetLimit)
    } else if totalFiles >= mediumFileThreshold {
      limit = min(limit, mediumSnippetLimit)
    }

    return max(limit, minSnippetLines)
  }
}

private func buildUserPrompt(
  displaySummary: ChangeSummary,
  fullSummary: ChangeSummary,
  metadata: PromptMetadata,
  isCompacted: Bool,
  remainder: RemainderContext
) -> Prompt {
  Prompt {
    metadata
    "Totals: \(fullSummary.fileCount) files; +\(fullSummary.totalAdditions) / -\(fullSummary.totalDeletions)"

    if isCompacted {
      "Context trimmed to stay within the model window; prioritize the most impactful changes."
    }

    if remainder.count > 0 {
      "Showing first \(displaySummary.fileCount) files (of \(fullSummary.fileCount)); remaining \(remainder.count) files contribute +\(remainder.additions) / -\(remainder.deletions)."

      for entry in remainder.kindBreakdown.prefix(4) {
        "  more: \(entry.count) \(entry.kind) file(s)"
      }

      if remainder.generatedCount > 0 {
        "  note: \(remainder.generatedCount) generated file(s) omitted per .gitattributes"
      }

      if !remainder.hintFiles.isEmpty {
        if remainder.remainingNonGeneratedCount > remainder.hintFiles.count {
          "  showing \(remainder.hintFiles.count) representative paths:"
        }
        for file in remainder.hintFiles {
          let descriptor = [
            file.kind,
            locationDescription(file.location),
            file.isBinary ? "binary" : nil,
            file.isGenerated ? "generated" : nil,
          ].compactMap { $0 }.joined(separator: ", ")
          "    • \(file.path) [\(descriptor)]"
        }
      }
    }

    displaySummary
  }
}

private func trimSummary(
  _ summary: ChangeSummary,
  fileLimit: Int,
  snippetLimit: Int
) -> ChangeSummary {
  let limitedFiles = summary.files.prefix(fileLimit).map { file -> ChangeSummary.FileSummary in
    var limited = file

    if snippetLimit <= 0 {
      if !limited.snippet.isEmpty {
        limited.snippet = []
        limited.snippetTruncated = true
      }
    } else if limited.snippet.count > snippetLimit {
      limited.snippet = Array(limited.snippet.prefix(snippetLimit))
      limited.snippetTruncated = true
    }

    return limited
  }

  return ChangeSummary(files: Array(limitedFiles))
}

private func estimatedLineCount(
  displaySummary: ChangeSummary,
  fullSummary: ChangeSummary,
  includesCompactionNote: Bool,
  remainder: RemainderContext
) -> Int {
  var total = 0

  // Metadata lines
  total += 4  // repository, branch, scope, style
  total += 1  // totals line

  if includesCompactionNote {
    total += 1
  }

  if remainder.count > 0 {
    total += 1  // showing first N files line

    total += min(4, remainder.kindBreakdown.count)

    if remainder.generatedCount > 0 {
      total += 1
    }

    if !remainder.hintFiles.isEmpty {
      if remainder.remainingNonGeneratedCount > remainder.hintFiles.count {
        total += 1
      }
      total += remainder.hintFiles.count
    }
  }

  for (index, file) in displaySummary.files.enumerated() {
    total += file.estimatedPromptLineCount()
    if index < displaySummary.files.count - 1 {
      total += 1  // blank line between file blocks
    }
  }

  return total
}

private struct RemainderContext {
  var count: Int = 0
  var additions: Int = 0
  var deletions: Int = 0
  var generatedCount: Int = 0
  var kindBreakdown: [PromptDiagnostics.KindCount] = []
  var hintFiles: [PromptDiagnostics.Hint] = []
  var remainingNonGeneratedCount: Int = 0

  static let empty = RemainderContext()
}

private func makeRemainderContext(
  fullSummary: ChangeSummary,
  displaySummary: ChangeSummary,
  hintLimit: Int
) -> RemainderContext {
  guard displaySummary.fileCount < fullSummary.fileCount else {
    return .empty
  }

  let remainderFiles = Array(fullSummary.files.dropFirst(displaySummary.fileCount))
  let additions = remainderFiles.reduce(0) { $0 + $1.additions }
  let deletions = remainderFiles.reduce(0) { $0 + $1.deletions }
  let generatedCount = remainderFiles.filter { $0.isGenerated }.count

  let groupedByKind = Dictionary(grouping: remainderFiles, by: { $0.kind.description })
    .mapValues { $0.count }
    .map { PromptDiagnostics.KindCount(kind: $0.key, count: $0.value) }
    .sorted { lhs, rhs in
      if lhs.count == rhs.count {
        return lhs.kind < rhs.kind
      }
      return lhs.count > rhs.count
    }

  let nonGenerated = remainderFiles.filter { !$0.isGenerated }
  let hints = Array(nonGenerated.prefix(hintLimit)).map { file in
    PromptDiagnostics.Hint(
      path: file.path,
      kind: file.kind.description,
      location: file.location,
      isBinary: file.isBinary,
      isGenerated: file.isGenerated
    )
  }

  return RemainderContext(
    count: remainderFiles.count,
    additions: additions,
    deletions: deletions,
    generatedCount: generatedCount,
    kindBreakdown: groupedByKind,
    hintFiles: hints,
    remainingNonGeneratedCount: nonGenerated.count
  )
}

private func makeDiagnostics(
  metadata: PromptMetadata,
  fullSummary: ChangeSummary,
  displaySummary: ChangeSummary,
  snippetLimit: Int,
  isCompacted: Bool,
  remainder: RemainderContext,
  estimatedLines: Int,
  lineBudget: Int,
  configuredFileLimit: Int,
  configuredSnippetLimit: Int,
  hintLimit: Int
) -> PromptDiagnostics {
  let totalGenerated = fullSummary.files.filter { $0.isGenerated }.count
  let displayedGenerated = displaySummary.files.filter { $0.isGenerated }.count
  let truncatedCount = displaySummary.files.filter { $0.snippetTruncated }.count
  let estimatedTokens = estimateTokenCount(
    metadata: metadata,
    displaySummary: displaySummary,
    fullSummary: fullSummary,
    isCompacted: isCompacted,
    remainder: remainder
  )
  let tokenLimit = 4_096
  let fileUsages = displaySummary.files.map { file -> PromptDiagnostics.FileUsage in
    let lines = file.promptLines()
    let characterCount = lines.reduce(0) { partial, line in
      partial + line.count + 1
    }
    let tokenEstimate = PromptDiagnostics.tokenEstimate(forCharacterCount: characterCount)
    return PromptDiagnostics.FileUsage(
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
  }

  return PromptDiagnostics(
    estimatedLineCount: estimatedLines,
    lineBudget: lineBudget,
    estimatedTokenCount: estimatedTokens,
    estimatedTokenLimit: tokenLimit,
    totalFiles: fullSummary.fileCount,
    displayedFiles: displaySummary.fileCount,
    configuredFileLimit: configuredFileLimit,
    snippetLineLimit: snippetLimit,
    configuredSnippetLineLimit: configuredSnippetLimit,
    snippetFilesTruncated: truncatedCount,
    compactionApplied: isCompacted,
    generatedFilesTotal: totalGenerated,
    generatedFilesDisplayed: displayedGenerated,
    fileUsages: fileUsages,
    remainderCount: remainder.count,
    remainderAdditions: remainder.additions,
    remainderDeletions: remainder.deletions,
    remainderGeneratedCount: remainder.generatedCount,
    remainderKindBreakdown: remainder.kindBreakdown,
    remainderHintLimit: hintLimit,
    remainderHintFiles: remainder.hintFiles,
    remainderNonGeneratedCount: remainder.remainingNonGeneratedCount
  )
}

private func estimateTokenCount(
  metadata: PromptMetadata,
  displaySummary: ChangeSummary,
  fullSummary: ChangeSummary,
  isCompacted: Bool,
  remainder: RemainderContext
) -> Int {
  var characterCount = 0

  func addLine(_ line: String) {
    characterCount += line.count + 1  // include newline separator
  }

  [
    "Repository: \(metadata.repositoryName)",
    "Branch: \(metadata.branchName)",
    "Scope: \(metadata.scopeDescription)",
    "Style: \(metadata.style)",
  ].forEach(addLine)

  addLine(
    "Totals: \(fullSummary.fileCount) files; +\(fullSummary.totalAdditions) / -\(fullSummary.totalDeletions)"
  )

  if isCompacted {
    addLine(
      "Context trimmed to stay within the model window; prioritize the most impactful changes."
    )
  }

  if remainder.count > 0 {
    addLine(
      "Showing first \(displaySummary.fileCount) files (of \(fullSummary.fileCount)); remaining \(remainder.count) files contribute +\(remainder.additions) / -\(remainder.deletions)."
    )

    for entry in remainder.kindBreakdown.prefix(4) {
      addLine("  more: \(entry.count) \(entry.kind) file(s)")
    }

    if remainder.generatedCount > 0 {
      addLine("  note: \(remainder.generatedCount) generated file(s) omitted per .gitattributes")
    }

    if !remainder.hintFiles.isEmpty {
      if remainder.remainingNonGeneratedCount > remainder.hintFiles.count {
        addLine("  showing \(remainder.hintFiles.count) representative paths:")
      }

      for file in remainder.hintFiles {
        let descriptor = [
          file.kind,
          locationDescription(file.location),
          file.isBinary ? "binary" : nil,
          file.isGenerated ? "generated" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        addLine("    • \(file.path) [\(descriptor)]")
      }
    }
  }

  for line in displaySummary.promptLines() {
    addLine(line)
  }

  let approximateCharactersPerToken = 4
  guard characterCount > 0 else { return 0 }
  return max(
    1,
    (characterCount + (approximateCharactersPerToken - 1)) / approximateCharactersPerToken
  )
}

private func locationDescription(_ location: GitChangeLocation) -> String {
  switch location {
  case .staged:
    "staged"
  case .unstaged:
    "unstaged"
  case .untracked:
    "untracked"
  }
}
