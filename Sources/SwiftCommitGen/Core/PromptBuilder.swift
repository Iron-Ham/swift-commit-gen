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
}

struct DefaultPromptBuilder: PromptBuilder {
  private let maxFiles: Int
  private let maxSnippetLines: Int

  init(maxFiles: Int = 12, maxSnippetLines: Int = 6) {
    self.maxFiles = maxFiles
    self.maxSnippetLines = maxSnippetLines
  }

  func makePrompt(summary: ChangeSummary, metadata: PromptMetadata) -> PromptPackage {
    let trimmedFiles = summary.files.prefix(maxFiles).map { file -> ChangeSummary.FileSummary in
      var limited = file
      if maxSnippetLines > 0, limited.snippet.count > maxSnippetLines {
        limited.snippet = Array(limited.snippet.prefix(maxSnippetLines))
        limited.snippetTruncated = true
      }
      return limited
    }

    let trimmedSummary = ChangeSummary(files: Array(trimmedFiles))
    let system = buildSystemPrompt(style: metadata.style)
    let user = buildUserPrompt(displaySummary: trimmedSummary, fullSummary: summary, metadata: metadata)
    return PromptPackage(systemPrompt: system, userPrompt: user)
  }

  private func buildSystemPrompt(style: CommitGenOptions.PromptStyle) -> Instructions {
    Instructions {
      "You're an AI assistant whose job is to concisely summarize code changes into short, useful commit messages, with a title and a description."

      "A changeset is given in the git diff output format, affecting one or multiple files."

      "The commit title should be no longer than 50 characters and should summarize the contents of the changeset for other developers reading the commit history."

      "The commit description can be longer, and should provide more context about the changeset, including why the changeset is being made, and any other relevant information."

      "The commit description is optional, so you can omit it if the changeset is small enough that it can be described in the commit title or if you don't have enough context."

      "Be brief and concise."

      "Do NOT include a description of changes in \"lock\" files from dependency managers like npm, yarn, or pip (and others), unless those are the only changes in the commit."

      "When more explanation is helpful, provide a short body with full sentences."

      "Leave the body empty when the subject already captures the change or the context is unclear."

      "For example:"
      CommitDraft(
        subject: "Fix issue with login form",
        body:
          "The login form was not submitting correctly. This commit fixes that issue by adding a missing name attribute to the submit button."
      )
    }
  }
}

private func buildUserPrompt(
  displaySummary: ChangeSummary,
  fullSummary: ChangeSummary,
  metadata: PromptMetadata
) -> Prompt {
  Prompt {
    metadata
    "Totals: \(fullSummary.fileCount) files; +\(fullSummary.totalAdditions) / -\(fullSummary.totalDeletions)"

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
    }

    displaySummary
  }
}
