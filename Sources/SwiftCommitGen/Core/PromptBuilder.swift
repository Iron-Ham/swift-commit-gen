import FoundationModels

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

protocol PromptBuilder {
  func makePrompt(summary: ChangeSummary, metadata: PromptMetadata) -> PromptPackage
}

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

  var estimatedLineCount: Int
  var lineBudget: Int
  var userContextLineCount: Int = 0

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

  var remainderCount: Int
  var remainderAdditions: Int
  var remainderDeletions: Int
  var remainderGeneratedCount: Int
  var remainderKindBreakdown: [KindCount]
  var remainderHintLimit: Int
  var remainderHintFiles: [Hint]
  var remainderNonGeneratedCount: Int

  mutating func recordAdditionalUserContext(lineCount: Int) {
    guard lineCount > 0 else { return }
    userContextLineCount += lineCount
    estimatedLineCount += lineCount
  }
}

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
    updatedDiagnostics.recordAdditionalUserContext(lineCount: additionalLines)

    return PromptPackage(
      systemPrompt: systemPrompt,
      userPrompt: augmentedUserPrompt,
      diagnostics: updatedDiagnostics
    )
  }
}

struct DefaultPromptBuilder: PromptBuilder {
  private let maxFiles: Int
  private let maxSnippetLines: Int
  private let maxPromptLineEstimate: Int
  private let minFiles: Int
  private let minSnippetLines: Int
  private let snippetReductionStep: Int
  private let hintThreshold: Int

  init(
    maxFiles: Int = 12,
    maxSnippetLines: Int = 6,
    maxPromptLineEstimate: Int = 400,
    minFiles: Int = 3,
    minSnippetLines: Int = 0,
    snippetReductionStep: Int = 2,
    hintThreshold: Int = 10
  ) {
    self.maxFiles = maxFiles
    self.maxSnippetLines = maxSnippetLines
    self.maxPromptLineEstimate = maxPromptLineEstimate
    self.minFiles = minFiles
    self.minSnippetLines = minSnippetLines
    self.snippetReductionStep = max(1, snippetReductionStep)
    self.hintThreshold = hintThreshold
  }

  func makePrompt(summary: ChangeSummary, metadata: PromptMetadata) -> PromptPackage {
    let system = buildSystemPrompt(style: metadata.style)

    var fileLimit = min(maxFiles, summary.fileCount)
    var snippetLimit = maxSnippetLines

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

    let finalCompaction = displaySummary.fileCount < summary.fileCount || snippetLimit < maxSnippetLines

    let diagnostics = makeDiagnostics(
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
      You're an AI assistant whose job is to concisely summarize code changes into short, useful commit messages, with a title and a description.
      A changeset is given in the git diff output format, affecting one or multiple files.

      The commit title should be no longer than 50 characters and should summarize the contents of the changeset for other developers reading the commit history.
      The commit description can be longer, and should provide more context about the changeset, including why the changeset is being made, and any other relevant information.
      The commit description is optional, so you can omit it if the changeset is small enough that it can be described in the commit title or if you don't have enough context.

      Be brief and concise.

      Do NOT include a description of changes in "lock" files from dependency managers like npm, yarn, or pip (and others), unless those are the only changes in the commit.

      When more explanation is helpful, provide a short body with full sentences.
      Leave the body empty when the subject already captures the change or the context is unclear.
      """
    }
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

  return PromptDiagnostics(
    estimatedLineCount: estimatedLines,
    lineBudget: lineBudget,
    totalFiles: fullSummary.fileCount,
    displayedFiles: displaySummary.fileCount,
    configuredFileLimit: configuredFileLimit,
    snippetLineLimit: snippetLimit,
    configuredSnippetLineLimit: configuredSnippetLimit,
    snippetFilesTruncated: truncatedCount,
    compactionApplied: isCompacted,
    generatedFilesTotal: totalGenerated,
    generatedFilesDisplayed: displayedGenerated,
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

private func locationDescription(_ location: GitChangeLocation) -> String {
  switch location {
  case .staged:
    return "staged"
  case .unstaged:
    return "unstaged"
  case .untracked:
    return "untracked"
  }
}
