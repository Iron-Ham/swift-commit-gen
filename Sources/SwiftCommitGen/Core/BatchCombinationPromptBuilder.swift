import Foundation

#if canImport(FoundationModels)
  @_weakLinked import FoundationModels
#endif

/// Builds the prompt used to merge per-batch drafts into a single commit message.
struct BatchCombinationPromptBuilder {
  /// Combines partial drafts alongside metadata so the model can assemble a cohesive commit.
  func makePrompt(metadata: PromptMetadata, partials: [BatchPartialDraft]) -> PromptPackage {
    precondition(!partials.isEmpty, "Expected at least one partial draft to combine")

    let sortedPartials = partials.sorted { $0.batchIndex < $1.batchIndex }
    var userLines: [String] = []

    userLines.append("Repository: \(metadata.repositoryName)")
    userLines.append("Branch: \(metadata.branchName)")
    userLines.append("Scope: \(metadata.scopeDescription)")
    userLines.append("Style: \(metadata.style.styleGuidance)")
    userLines.append(
      "We split the diff into \(sortedPartials.count) batch(es) to respect the model context window. Combine the partial commit drafts below into a single cohesive commit message that covers every file."
    )

    for partial in sortedPartials {
      let additions = partial.files.reduce(0) { $0 + $1.additions }
      let deletions = partial.files.reduce(0) { $0 + $1.deletions }
      userLines.append("")
      userLines.append(
        "Batch \(partial.batchIndex + 1): \(partial.files.count) file(s); +\(additions) / -\(deletions)"
      )

      if !partial.files.isEmpty {
        let previewPaths = partial.files.prefix(8).map { $0.path }
        if previewPaths.count == partial.files.count {
          userLines.append("Files: \(previewPaths.joined(separator: ", "))")
        } else {
          let remaining = partial.files.count - previewPaths.count
          userLines.append("Files: \(previewPaths.joined(separator: ", ")) (+\(remaining) more)")
        }
      }

      let subject = partial.draft.subject.isEmpty ? "(empty subject)" : partial.draft.subject
      userLines.append("Partial subject: \(subject)")

      if let body = partial.draft.body,
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        userLines.append("Partial body:")
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
          userLines.append("  \(String(line))")
        }
      }
    }

    userLines.append("")
    userLines.append(
      "Produce one final commit subject (<= 50 characters) and an optional body that summarizes the full change set. Avoid repeating the batch headings—present the combined commit message only."
    )

    #if canImport(FoundationModels)
      let userPrompt = Prompt {
        for line in userLines {
          line
        }
      }

      let systemPrompt = Instructions {
        """
        You are an AI assistant merging multiple partial commit drafts into a single, well-structured commit message. 
        Preserve all important intent from the inputs, avoid redundancy, and keep the final subject concise (<= 50 characters). 
        The title should succinctly describe the change in a specific and informative manner.
        Provide an optional body only when useful for additional context. 
        If a body is present, it should describe the _purpose_ of the change, not just _what_ was changed: focus on the reasoning behind the changes rather than a file-by-file summary.

        Be clear and concise, but do not omit critical information.
        """
        ""
        metadata.style.styleGuidance
      }
    #else
      let userPrompt = PromptContent(userLines.joined(separator: "\n"))

      let systemPrompt = PromptContent(
        """
        You are an AI assistant merging multiple partial commit drafts into a single, well-structured commit message. 
        Preserve all important intent from the inputs, avoid redundancy, and keep the final subject concise (<= 50 characters). 
        The title should succinctly describe the change in a specific and informative manner.
        Provide an optional body only when useful for additional context. 
        If a body is present, it should describe the _purpose_ of the change, not just _what_ was changed: focus on the reasoning behind the changes rather than a file-by-file summary.

        Be clear and concise, but do not omit critical information.

        \(metadata.style.styleGuidance)
        """
      )
    #endif

    let characterCount = userLines.reduce(0) { $0 + $1.count + 1 }
    let estimatedTokens = PromptDiagnostics.tokenEstimate(forCharacterCount: characterCount)
    let uniqueFiles = Set(sortedPartials.flatMap { $0.files }.map { $0.path })
    let generatedFileCount = sortedPartials.flatMap { $0.files }.filter { $0.isGenerated }.count

    let diagnostics = PromptDiagnostics(
      estimatedLineCount: userLines.count,
      lineBudget: 400,
      estimatedTokenCount: estimatedTokens,
      estimatedTokenLimit: 4_096,
      totalFiles: uniqueFiles.count,
      displayedFiles: uniqueFiles.count,
      configuredFileLimit: uniqueFiles.count,
      snippetLineLimit: 0,
      configuredSnippetLineLimit: 0,
      snippetFilesTruncated: 0,
      compactionApplied: false,
      generatedFilesTotal: generatedFileCount,
      generatedFilesDisplayed: generatedFileCount,
      fileUsages: sortedPartials.flatMap { $0.diagnostics.fileUsages },
      remainderCount: 0,
      remainderAdditions: 0,
      remainderDeletions: 0,
      remainderGeneratedCount: 0,
      remainderKindBreakdown: [],
      remainderHintLimit: 0,
      remainderHintFiles: [],
      remainderNonGeneratedCount: 0
    )

    return PromptPackage(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      diagnostics: diagnostics
    )
  }
}
