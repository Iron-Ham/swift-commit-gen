import Foundation
import FoundationModels

/// LLM output structure for the overview pass.
@Generable(description: "A high-level overview of a large changeset.")
struct ChangesetOverview: Hashable, Codable, Sendable {
  @Guide(
    description:
      "A concise summary (2-3 sentences) describing the overall purpose and scope of the changes."
  )
  var summary: String

  @Guide(
    description:
      "The primary category of this changeset: feature, bugfix, refactor, test, docs, or chore."
  )
  var category: String

  @Guide(
    description:
      "List of the most important files that are central to understanding the changeset (up to 5 paths)."
  )
  var keyFiles: [String]

  init(summary: String = "", category: String = "", keyFiles: [String] = []) {
    self.summary = summary
    self.category = category
    self.keyFiles = keyFiles
  }
}

/// Builds a lightweight prompt with file metadata only (no diff snippets).
///
/// This is used in the first pass of two-pass analysis to get a high-level
/// understanding of large changesets before detailed batch processing.
struct OverviewPromptBuilder {
  /// Creates a metadata-only prompt for overview generation.
  func makePrompt(summary: ChangeSummary, metadata: PromptMetadata) -> PromptPackage {
    let system = buildSystemPrompt()
    let user = buildUserPrompt(summary: summary, metadata: metadata)
    let diagnostics = makeDiagnostics(summary: summary)

    return PromptPackage(
      systemPrompt: system,
      userPrompt: user,
      diagnostics: diagnostics
    )
  }

  private func buildSystemPrompt() -> Instructions {
    Instructions {
      """
      You are an AI assistant analyzing a large set of code changes to provide a high-level overview.
      Your task is to understand the overall purpose of the changeset based on file metadata and change hints.

      Focus on:
      1. Identifying the primary intent of the changes (feature, bugfix, refactor, etc.)
      2. Recognizing which files are most central to the change
      3. Summarizing the scope and impact of the changes

      You do NOT have access to the actual diff content - only file paths, change types, and semantic hints.
      Base your analysis on the patterns you observe in the file names, directories, and change characteristics.
      """
    }
  }

  private func buildUserPrompt(summary: ChangeSummary, metadata: PromptMetadata) -> Prompt {
    Prompt {
      "Repository: \(metadata.repositoryName)"
      "Branch: \(metadata.branchName)"
      "Total files changed: \(summary.fileCount)"
      "Total additions: +\(summary.totalAdditions)"
      "Total deletions: -\(summary.totalDeletions)"
      ""
      "File changes (metadata only):"

      for file in summary.files {
        fileMetadataLine(for: file)
      }

      ""
      "Based on this metadata, provide a high-level overview of what this changeset accomplishes."
      "Identify the most important files that are central to understanding the changes."
    }
  }

  private func fileMetadataLine(for file: ChangeSummary.FileSummary) -> String {
    var components: [String] = []

    // Path and change type
    components.append("- \(file.path)")
    components.append("[\(file.kind.description)]")

    // Stats
    components.append("+\(file.additions)/-\(file.deletions)")

    // Semantic hints if available
    if !file.changeHints.isEmpty {
      components.append("hints: \(file.changeHints.joined(separator: ", "))")
    }

    // Special flags
    var flags: [String] = []
    if file.isGenerated { flags.append("generated") }
    if file.isBinary { flags.append("binary") }
    if !flags.isEmpty {
      components.append("(\(flags.joined(separator: ", ")))")
    }

    return components.joined(separator: " ")
  }

  private func makeDiagnostics(summary: ChangeSummary) -> PromptDiagnostics {
    // Calculate approximate token count for the overview prompt
    var characterCount = 0

    // Metadata header
    characterCount += 200  // Approximate fixed overhead

    // File metadata lines (much shorter than full diffs)
    for file in summary.files {
      characterCount += file.path.count + 50  // path + metadata
      characterCount += file.changeHints.joined(separator: ", ").count
    }

    let estimatedTokens = PromptDiagnostics.tokenEstimate(forCharacterCount: characterCount)
    let generatedCount = summary.files.filter { $0.isGenerated }.count

    return PromptDiagnostics(
      estimatedLineCount: summary.fileCount + 10,
      lineBudget: 500,
      estimatedTokenCount: estimatedTokens,
      estimatedTokenLimit: 4_096,
      totalFiles: summary.fileCount,
      displayedFiles: summary.fileCount,
      configuredFileLimit: summary.fileCount,
      snippetLineLimit: 0,  // No snippets in overview
      configuredSnippetLineLimit: 0,
      snippetFilesTruncated: 0,
      compactionApplied: false,
      generatedFilesTotal: generatedCount,
      generatedFilesDisplayed: generatedCount,
      fileUsages: [],  // No detailed file usage in overview
      remainderCount: 0,
      remainderAdditions: 0,
      remainderDeletions: 0,
      remainderGeneratedCount: 0,
      remainderKindBreakdown: [],
      remainderHintLimit: 0,
      remainderHintFiles: [],
      remainderNonGeneratedCount: 0
    )
  }
}
