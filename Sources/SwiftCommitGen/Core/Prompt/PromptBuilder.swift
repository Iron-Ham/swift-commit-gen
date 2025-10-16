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
      "You are an experienced developer drafting Git commit messages from change summaries.")
    lines.append("Follow these rules:")
    lines.append("1. Never invent modifications that are not described in the summary.")
    lines.append("2. Keep the subject line at or below 72 characters and use present tense.")
    lines.append("3. Separate the subject and body with a blank line when a body is needed.")
    lines.append(
      "4. Output plain text only; avoid Markdown emphasis, headings, or fenced code blocks.")
    lines.append(
      "5. Describe the overall intent of the changes instead of listing each file individually.")
    lines.append(
      "6. Begin with the commit subject directly; do not prefix it with labels like 'Subject:'.")
    lines.append(
      "7. Output a subject (<=72 chars) followed by an optional body separated by a single blank line; omit trailing code fences or repeated subjects.")
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
        "Style: produce a one-line subject whenever possible; if a body is required, use a short sentence or two without bullet lists."
    case .conventional:
      return
        "Style: use Conventional Commits (type: subject) and add an optional bullet list body highlighting key changes."
    case .detailed:
      return
        "Style: include a concise subject followed by a multi-bullet body summarizing the major code edits and rationale."
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
