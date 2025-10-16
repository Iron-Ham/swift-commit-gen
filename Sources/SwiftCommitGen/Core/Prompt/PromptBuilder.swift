struct PromptMetadata {
  var repositoryName: String
  var branchName: String
  var style: CommitGenOptions.PromptStyle
  var includeUnstagedChanges: Bool
  var additionalInstructions: [String]

  init(
    repositoryName: String,
    branchName: String,
    style: CommitGenOptions.PromptStyle,
    includeUnstagedChanges: Bool,
    additionalInstructions: [String] = []
  ) {
    self.repositoryName = repositoryName
    self.branchName = branchName
    self.style = style
    self.includeUnstagedChanges = includeUnstagedChanges
    self.additionalInstructions = additionalInstructions
  }

  var scopeDescription: String {
    includeUnstagedChanges ? "staged + unstaged changes" : "staged changes only"
  }
}

protocol PromptBuilder {
  func makePrompt(summary: ChangeSummary, metadata: PromptMetadata) -> PromptPackage
}

struct PromptPackage {
  var systemPrompt: String
  var userPrompt: String

  init(systemPrompt: String = "", userPrompt: String = "") {
    self.systemPrompt = systemPrompt
    self.userPrompt = userPrompt
  }
}

struct DefaultPromptBuilder: PromptBuilder {
  private let maxFiles: Int
  private let maxSnippetLines: Int

  init(maxFiles: Int = 20, maxSnippetLines: Int = 8) {
    self.maxFiles = maxFiles
    self.maxSnippetLines = maxSnippetLines
  }

  func makePrompt(summary: ChangeSummary, metadata: PromptMetadata) -> PromptPackage {
    let trimmedSummary = ChangeSummary(files: Array(summary.files.prefix(maxFiles)))
    let system = buildSystemPrompt(
      style: metadata.style, additional: metadata.additionalInstructions)
    let user = buildUserPrompt(summary: trimmedSummary, metadata: metadata)
    return PromptPackage(systemPrompt: system, userPrompt: user)
  }

  private func buildSystemPrompt(
    style: CommitGenOptions.PromptStyle, additional: [String]
  ) -> String {
    var lines: [String] = []
    lines.append(
      "You're an AI assistant whose job is to concisely summarize code changes into short, useful commit messages, with a title and a description.")
    lines.append("")
    lines.append(
      "A changeset is given in the git diff output format, affecting one or multiple files.")
    lines.append("")
    lines.append(
      "The commit title should be no longer than 50 characters and should summarize the contents of the changeset for other developers reading the commit history.")
    lines.append("")
    lines.append(
      "The commit description can be longer, and should provide more context about the changeset, including why the changeset is being made, and any other relevant information."
    )
    lines.append(
      "The commit description is optional, so you can omit it if the changeset is small enough that it can be described in the commit title or if you don't have enough context.")
    lines.append("")
    lines.append("Be brief and concise.")
    lines.append("")
    lines.append(
      "Do NOT include a description of changes in \"lock\" files from dependency managers like npm, yarn, or pip (and others), unless those are the only changes in the commit.")
    lines.append("")
    lines.append(
      "Your response must be a JSON object with the attributes \"title\" and \"description\" containing the commit title and commit description. Do not use markdown to wrap the JSON object, just return it as plain text.")
    lines.append("For example:")
    lines.append("")
    lines.append(#"{ "title": "Fix issue with login form", "description": "The login form was not submitting correctly. This commit fixes that issue by adding a missing name attribute to the submit button." }"#)
    lines.append("")
    lines.append(styleGuidance(for: style))

    if !additional.isEmpty {
      lines.append("Additional project guidance:")
      for note in additional {
        lines.append("- \(note)")
      }
    }

    return lines.joined(separator: "\n")
  }

  private func styleGuidance(for style: CommitGenOptions.PromptStyle) -> String {
    switch style {
    case .summary:
      return
        "Style: keep the JSON \"description\" empty when the \"title\" fully captures the change; avoid bullet lists or markdown in either field."
    case .conventional:
      return
        "Style: format the JSON \"title\" using Conventional Commits (type: subject) within 50 characters; keep the \"description\" to brief plain sentences without markdown."
    case .detailed:
      return
        "Style: use the JSON \"description\" for a few short sentences covering rationale and impact; separate points with sentences rather than markdown bullets."
    }
  }

  private func buildUserPrompt(summary: ChangeSummary, metadata: PromptMetadata) -> String {
    var lines: [String] = []
    lines.append("Repository: \(metadata.repositoryName)")
    lines.append("Branch: \(metadata.branchName)")
    lines.append("Scope: \(metadata.scopeDescription)")
    lines.append(
      "Totals: \(summary.fileCount) files, +\(summary.totalAdditions), -\(summary.totalDeletions)")
    lines.append("")
    lines.append("Changes:")

    if summary.files.isEmpty {
      lines.append("- No file details captured.")
    } else {
      for file in summary.files {
        lines.append(contentsOf: describe(file: file))
      }
    }

    return lines.joined(separator: "\n")
  }

  private func describe(file: ChangeSummary.FileSummary) -> [String] {
    var output: [String] = []

    var identifier = file.path
    if let old = file.oldPath, old != file.path {
      identifier = "\(old) -> \(file.path)"
    }

    let header =
      "- \(identifier) [\(file.kind.description); \(scopeLabel(for: file.location)); +\(file.additions)/-\(file.deletions)]"
    output.append(header)

    let snippetLines = file.snippet.prefix(maxSnippetLines)
    if snippetLines.isEmpty {
      output.append("  (no diff snippet available)")
    } else {
      for line in snippetLines {
        output.append("  \(line)")
      }
      if file.snippet.count > maxSnippetLines {
        output.append("  ... (truncated)")
      }
    }

    return output
  }

  private func scopeLabel(for location: GitChangeLocation) -> String {
    switch location {
    case .staged:
      return "staged"
    case .unstaged:
      return "unstaged"
    case .untracked:
      return "untracked"
    }
  }
}
