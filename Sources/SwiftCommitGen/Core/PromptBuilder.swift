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

struct PromptPackage {
  var systemPrompt: Instructions
  var userPrompt: Prompt

  func appendingUserContext(_ context: String) -> PromptPackage {
    let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return self }

    let augmentedUserPrompt = Prompt {
      userPrompt
      ""
      "Additional context from user:"
      trimmed
    }

    return PromptPackage(systemPrompt: systemPrompt, userPrompt: augmentedUserPrompt)
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

    var fileLimit = min(maxFiles, summary.files.count)
    var snippetLimit = maxSnippetLines

    var displaySummary = trimSummary(summary, fileLimit: fileLimit, snippetLimit: snippetLimit)
    var isCompacted = displaySummary.fileCount < summary.fileCount || snippetLimit < maxSnippetLines

    var user = buildUserPrompt(
      displaySummary: displaySummary,
      fullSummary: summary,
      metadata: metadata,
      isCompacted: isCompacted,
      hintLimit: hintThreshold
    )

    var estimate = estimatedLineCount(
      displaySummary: displaySummary,
      fullSummary: summary,
      includesCompactionNote: isCompacted,
      hintLimit: hintThreshold
    )

    while estimate > maxPromptLineEstimate {
      let previousSnippet = snippetLimit
      let previousFileLimit = fileLimit

      if snippetLimit > minSnippetLines {
        snippetLimit = max(minSnippetLines, snippetLimit - snippetReductionStep)
      } else if fileLimit > minFiles {
        fileLimit = max(minFiles, fileLimit - 1)
      } else {
        break
      }

      displaySummary = trimSummary(summary, fileLimit: fileLimit, snippetLimit: snippetLimit)
      isCompacted =
        displaySummary.fileCount < summary.fileCount
        || snippetLimit < maxSnippetLines
        || fileLimit < previousFileLimit
        || snippetLimit < previousSnippet

      user = buildUserPrompt(
        displaySummary: displaySummary,
        fullSummary: summary,
        metadata: metadata,
        isCompacted: isCompacted,
        hintLimit: hintThreshold
      )

      estimate = estimatedLineCount(
        displaySummary: displaySummary,
        fullSummary: summary,
        includesCompactionNote: isCompacted,
        hintLimit: hintThreshold
      )
    }

    return PromptPackage(systemPrompt: system, userPrompt: user)
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
  hintLimit: Int
) -> Prompt {
  Prompt {
    metadata
    "Totals: \(fullSummary.fileCount) files; +\(fullSummary.totalAdditions) / -\(fullSummary.totalDeletions)"

    if isCompacted {
      "Context trimmed to stay within the model window; prioritize the most impactful changes."
    }

    if displaySummary.fileCount < fullSummary.fileCount {
      let remainder = Array(fullSummary.files.dropFirst(displaySummary.fileCount))
      let remainderAdditions = remainder.reduce(0) { $0 + $1.additions }
      let remainderDeletions = remainder.reduce(0) { $0 + $1.deletions }
      "Showing first \(displaySummary.fileCount) files (of \(fullSummary.fileCount)); remaining \(remainder.count) files contribute +\(remainderAdditions) / -\(remainderDeletions)."

      let groupedByKind = Dictionary(grouping: remainder, by: { $0.kind.description })
        .mapValues { $0.count }
        .sorted { lhs, rhs in
          if lhs.value == rhs.value {
            return lhs.key < rhs.key
          }
          return lhs.value > rhs.value
        }

      for (kind, count) in groupedByKind.prefix(4) {
        "  more: \(count) \(kind) file(s)"
      }

      let generatedCount = remainder.filter { $0.isGenerated }.count
      if generatedCount > 0 {
        "  note: \(generatedCount) generated file(s) omitted per .gitattributes"
      }

      let nonGeneratedRemainder = remainder.filter { !$0.isGenerated }
      let hintCandidates = Array(nonGeneratedRemainder.prefix(hintLimit))
      if nonGeneratedRemainder.count > hintLimit {
        "  showing \(hintLimit) representative paths:"
      }
      for file in hintCandidates {
        let descriptor = [
          file.kind.description,
          locationDescription(file.location),
          file.isBinary ? "binary" : nil,
          file.isGenerated ? "generated" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        "    • \(file.path) [\(descriptor)]"
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
  hintLimit: Int
) -> Int {
  var total = 0

  // Metadata lines
  total += 4  // repository, branch, scope, style
  total += 1  // totals line

  if includesCompactionNote {
    total += 1
  }

  if displaySummary.fileCount < fullSummary.fileCount {
    total += 1  // showing first N files

    let remainder = Array(fullSummary.files.dropFirst(displaySummary.fileCount))
    let groupedByKind = Dictionary(grouping: remainder, by: { $0.kind.description })
      .mapValues { $0.count }
      .sorted { lhs, rhs in
        if lhs.value == rhs.value {
          return lhs.key < rhs.key
        }
        return lhs.value > rhs.value
      }

    total += min(4, groupedByKind.count)

    let generatedCount = remainder.filter { $0.isGenerated }.count
    if generatedCount > 0 {
      total += 1
    }

    let nonGeneratedRemainder = remainder.filter { !$0.isGenerated }
    let hintCandidates = Array(nonGeneratedRemainder.prefix(hintLimit))
    if nonGeneratedRemainder.count > hintLimit {
      total += 1
    }
    total += hintCandidates.count
  }

  for (index, file) in displaySummary.files.enumerated() {
    total += file.estimatedPromptLineCount()
    if index < displaySummary.files.count - 1 {
      total += 1  // blank line between file blocks
    }
  }

  return total
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
