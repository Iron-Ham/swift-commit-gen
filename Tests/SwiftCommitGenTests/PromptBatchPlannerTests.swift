import Foundation
import Testing

@testable import SwiftCommitGen

struct PromptBatchPlannerTests {
  @Test("Promotes full snippets when budget allows")
  func promotesFullSnippets() {
    let compactSnippet = ["@@", "-old", "+new"]
    let fullSnippet = (0..<20).map { "context line " + String($0) }

    let file = makeFileSummary(
      path: "Sources/App/File.swift",
      compactSnippet: compactSnippet,
      fullSnippet: fullSnippet,
      isGenerated: false,
      isBinary: false
    )

    let planner = PromptBatchPlanner(tokenBudget: 400, headroomRatio: 0.1)
    let batches = planner.planBatches(for: ChangeSummary(files: [file]))

    #expect(batches.count == 1)
    let batch = batches[0]
    #expect(batch.files.count == 1)
    #expect(batch.files[0].snippetMode == .full)
    #expect(batch.files[0].snippet == fullSnippet)
    #expect(batch.fileUsages[0].usedFullSnippet == true)
    #expect(batch.fileUsages[0].snippetTruncated == false)
  }

  @Test("Keeps compact snippets when full would exceed budget")
  func keepsCompactSnippetsWhenOverBudget() {
    let compactSnippet = ["short"]
    let fullSnippet = (0..<120).map { _ in String(repeating: "x", count: 160) }

    let file = makeFileSummary(
      path: "Sources/App/Large.swift",
      compactSnippet: compactSnippet,
      fullSnippet: fullSnippet,
      isGenerated: false,
      isBinary: false,
      diffLineCount: fullSnippet.count
    )

    let planner = PromptBatchPlanner(tokenBudget: 200, headroomRatio: 0.1)
    let batches = planner.planBatches(for: ChangeSummary(files: [file]))

    #expect(batches.count == 1)
    let batch = batches[0]
    #expect(batch.files[0].snippetMode == .compact)
    #expect(batch.files[0].snippet == compactSnippet)
    #expect(batch.fileUsages[0].usedFullSnippet == false)
  }

  @Test("Generated files remain compact even with budget")
  func generatedFilesStayCompact() {
    let compactSnippet: [String] = []
    let fullSnippet: [String] = []

    let file = makeFileSummary(
      path: "gen/Foo.swift",
      compactSnippet: compactSnippet,
      fullSnippet: fullSnippet,
      isGenerated: true,
      isBinary: false,
      diffLineCount: 0
    )

    let planner = PromptBatchPlanner(tokenBudget: 500, headroomRatio: 0.1)
    let batches = planner.planBatches(for: ChangeSummary(files: [file]))

    #expect(batches.count == 1)
    let batch = batches[0]
    #expect(batch.fileUsages[0].isGenerated == true)
    #expect(batch.files[0].snippet.isEmpty)
  }

  @Test("Splits oversized files into separate batches")
  func splitsOversizedFilesIntoSeparateBatches() {
    let largeSnippet = makeSnippet(lineCount: 60, prefix: "context")
    let files = (0..<3).map { index -> ChangeSummary.FileSummary in
      let path = "Sources/Large/File" + String(index) + ".swift"
      return makeFileSummary(
        path: path,
        compactSnippet: largeSnippet,
        fullSnippet: largeSnippet,
        isGenerated: false,
        isBinary: false,
        diffLineCount: largeSnippet.count
      )
    }

    let tokenBudget = 600
    let headroomRatio = 0.1
    let targetBudget = max(1, Int(Double(tokenBudget) * (1.0 - headroomRatio)))

    let planner = PromptBatchPlanner(tokenBudget: tokenBudget, headroomRatio: headroomRatio)
    let batches = planner.planBatches(for: ChangeSummary(files: files))

    #expect(batches.count == files.count)

    for (index, batch) in batches.enumerated() {
      #expect(batch.files.count == 1)
      let compactTokens = tokenEstimate(for: files[index], mode: .compact)
      #expect(compactTokens > targetBudget)
      #expect(batch.exceedsBudget == true)
    }
  }

  @Test("Upgrades smallest delta first when budget is tight")
  func upgradesSmallestDeltaFirst() {
    let compactA = makeSnippet(lineCount: 4, prefix: "alpha")
    let fullA = makeSnippet(lineCount: 20, prefix: "alpha")
    let compactB = makeSnippet(lineCount: 4, prefix: "bravo")
    let fullB = makeSnippet(lineCount: 60, prefix: "bravo")

    let fileA = makeFileSummary(
      path: "Sources/App/FileA.swift",
      compactSnippet: compactA,
      fullSnippet: fullA,
      isGenerated: false,
      isBinary: false,
      diffLineCount: fullA.count
    )

    let fileB = makeFileSummary(
      path: "Sources/App/FileB.swift",
      compactSnippet: compactB,
      fullSnippet: fullB,
      isGenerated: false,
      isBinary: false,
      diffLineCount: fullB.count
    )

    let compactTotal =
      tokenEstimate(for: fileA, mode: .compact)
      + tokenEstimate(for: fileB, mode: .compact)
    let deltaA = tokenEstimate(for: fileA, mode: .full) - tokenEstimate(for: fileA, mode: .compact)
    let deltaB = tokenEstimate(for: fileB, mode: .full) - tokenEstimate(for: fileB, mode: .compact)

    #expect(deltaB > deltaA)

    let planner = PromptBatchPlanner(
      tokenBudget: compactTotal + deltaA + 1,
      headroomRatio: 0.0
    )

    let batches = planner.planBatches(for: ChangeSummary(files: [fileA, fileB]))

    #expect(batches.count == 1)
    let batch = batches[0]
    #expect(batch.files.count == 2)
    #expect(batch.tokenEstimate <= compactTotal + deltaA + 1)

    let usagesByPath = Dictionary(uniqueKeysWithValues: batch.fileUsages.map { ($0.path, $0) })
    #expect(usagesByPath["Sources/App/FileA.swift"]?.usedFullSnippet == true)
    #expect(usagesByPath["Sources/App/FileB.swift"]?.usedFullSnippet == false)
  }

  @Test("Returns no batches for empty summaries")
  func emptySummariesProduceNoBatches() {
    let planner = PromptBatchPlanner(tokenBudget: 100, headroomRatio: 0.2)
    let batches = planner.planBatches(for: ChangeSummary(files: []))
    #expect(batches.isEmpty)
  }

  private func makeFileSummary(
    path: String,
    compactSnippet: [String],
    fullSnippet: [String],
    isGenerated: Bool,
    isBinary: Bool,
    diffLineCount: Int? = nil
  ) -> ChangeSummary.FileSummary {
    let diffLines = diffLineCount ?? max(fullSnippet.count, compactSnippet.count)
    return ChangeSummary.FileSummary(
      path: path,
      oldPath: nil,
      kind: .modified,
      location: .staged,
      additions: 10,
      deletions: 5,
      snippet: compactSnippet,
      compactSnippet: compactSnippet,
      fullSnippet: fullSnippet,
      snippetMode: .compact,
      snippetTruncated: false,
      isBinary: isBinary,
      diffLineCount: diffLines,
      diffHasHunks: true,
      isGenerated: isGenerated
    )
  }

  private func makeSnippet(lineCount: Int, prefix: String) -> [String] {
    (0..<lineCount).map { index in
      let indexText = String(index)
      return prefix + " line " + indexText + ": " + String(repeating: "x", count: 120)
    }
  }

  private func tokenEstimate(
    for file: ChangeSummary.FileSummary,
    mode: ChangeSummary.FileSummary.SnippetMode
  ) -> Int {
    let configured = file.withSnippetMode(mode)
    let characterCount = configured.promptLines().reduce(0) { partial, line in
      partial + line.count + 1
    }
    return PromptDiagnostics.tokenEstimate(forCharacterCount: characterCount)
  }
}
