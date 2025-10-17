import Foundation
import Testing

@testable import SwiftCommitGen

struct BatchCombinationPromptBuilderTests {
  @Test("Aggregates partial drafts and sorts by batch index")
  func aggregatesAndSortsPartials() {
    let metadata = PromptMetadata(
      repositoryName: "DemoRepo",
      branchName: "feature/batch",
      style: .summary,
      includeUnstagedChanges: false
    )

    let higherIndex = makePartial(
      index: 2,
      filePath: "Sources/Feature/Later.swift",
      additions: 6,
      deletions: 3,
      isGenerated: false,
      usedFullSnippet: false
    )

    let lowerIndex = makePartial(
      index: 0,
      filePath: "Sources/Feature/Earlier.swift",
      additions: 4,
      deletions: 1,
      isGenerated: true,
      usedFullSnippet: true
    )

    let builder = BatchCombinationPromptBuilder()
    let package = builder.makePrompt(metadata: metadata, partials: [higherIndex, lowerIndex])

    let usagePaths = package.diagnostics.fileUsages.map { $0.path }
    #expect(usagePaths == ["Sources/Feature/Earlier.swift", "Sources/Feature/Later.swift"])

    #expect(package.diagnostics.totalFiles == 2)
    #expect(package.diagnostics.generatedFilesTotal == 1)
    #expect(package.diagnostics.generatedFilesDisplayed == 1)
    #expect(package.diagnostics.estimatedLineCount > 0)
    #expect(package.diagnostics.estimatedTokenCount > 0)

    let description = String(describing: package.userPrompt)
    #expect(description.contains("Repository: DemoRepo"))
    #expect(description.contains("Batch 1"))
    #expect(description.contains("Batch 3"))
  }

  @Test("Diagnostics include merged file usages from partials")
  func diagnosticsIncludeMergedFileUsages() {
    let metadata = PromptMetadata(
      repositoryName: "Example",
      branchName: "main",
      style: .detailed,
      includeUnstagedChanges: true
    )

    let first = makePartial(
      index: 1,
      filePath: "Docs/Guide.md",
      additions: 2,
      deletions: 0,
      isGenerated: false,
      usedFullSnippet: false
    )

    let second = makePartial(
      index: 2,
      filePath: "Scripts/build.sh",
      additions: 1,
      deletions: 1,
      isGenerated: false,
      usedFullSnippet: true
    )

    let package = BatchCombinationPromptBuilder().makePrompt(
      metadata: metadata,
      partials: [first, second]
    )

    #expect(package.diagnostics.fileUsages.count == 2)
    let usages = package.diagnostics.fileUsages
    #expect(usages.allSatisfy { $0.tokenEstimate > 0 })
    #expect(usages.contains { $0.path == "Docs/Guide.md" && $0.usedFullSnippet == false })
    #expect(usages.contains { $0.path == "Scripts/build.sh" && $0.usedFullSnippet == true })
    #expect(package.diagnostics.tokenEstimateMatchesUsageSum())
    #expect(package.diagnostics.estimatedLineCount >= 14)

    let instructions = String(describing: package.systemPrompt)
    #expect(instructions.contains("You are an AI assistant"))
  }

  private func makePartial(
    index: Int,
    filePath: String,
    additions: Int,
    deletions: Int,
    isGenerated: Bool,
    usedFullSnippet: Bool
  ) -> BatchPartialDraft {
    let file = ChangeSummary.FileSummary(
      path: filePath,
      oldPath: nil,
      kind: .modified,
      location: .staged,
      additions: additions,
      deletions: deletions,
      snippet: [],
      compactSnippet: [],
      fullSnippet: [],
      snippetMode: usedFullSnippet ? .full : .compact,
      snippetTruncated: false,
      isBinary: false,
      diffLineCount: additions + deletions,
      diffHasHunks: true,
      isGenerated: isGenerated
    )

    let usage = PromptDiagnostics.FileUsage(
      path: filePath,
      kind: file.kind.description,
      location: .staged,
      lineCount: max(1, additions + deletions),
      tokenEstimate: PromptDiagnostics.tokenEstimate(
        forCharacterCount: max(1, additions + deletions) * 40),
      isGenerated: isGenerated,
      isBinary: false,
      snippetTruncated: false,
      usedFullSnippet: usedFullSnippet
    )

    let diagnostics = PromptDiagnostics(
      estimatedLineCount: 6,
      lineBudget: 400,
      estimatedTokenCount: PromptDiagnostics.tokenEstimate(forCharacterCount: 280),
      estimatedTokenLimit: 4_096,
      totalFiles: 1,
      displayedFiles: 1,
      configuredFileLimit: 1,
      snippetLineLimit: 0,
      configuredSnippetLineLimit: 0,
      snippetFilesTruncated: 0,
      compactionApplied: false,
      generatedFilesTotal: isGenerated ? 1 : 0,
      generatedFilesDisplayed: isGenerated ? 1 : 0,
      fileUsages: [usage],
      remainderCount: 0,
      remainderAdditions: 0,
      remainderDeletions: 0,
      remainderGeneratedCount: 0,
      remainderKindBreakdown: [],
      remainderHintLimit: 0,
      remainderHintFiles: [],
      remainderNonGeneratedCount: isGenerated ? 0 : 1
    )

    return BatchPartialDraft(
      batchIndex: index,
      files: [file],
      draft: CommitDraft(subject: "Partial subject \(index)", body: "Body text \(index)"),
      diagnostics: diagnostics
    )
  }
}

extension PromptDiagnostics {
  fileprivate func tokenEstimateMatchesUsageSum() -> Bool {
    let usageTotal = fileUsages.reduce(0) { $0 + $1.tokenEstimate }
    return usageTotal <= estimatedTokenCount || estimatedTokenCount == 0
  }
}
