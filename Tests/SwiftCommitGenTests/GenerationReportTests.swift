import Foundation
import Testing

@testable import SwiftCommitGen

struct GenerationReportTests {
  @Test("Encodes batched report with nested diagnostics")
  func encodesBatchedReport() throws {
    let diagnostics = PromptDiagnostics(
      estimatedLineCount: 10,
      lineBudget: 400,
      estimatedTokenCount: 120,
      estimatedTokenLimit: 4_096,
      totalFiles: 2,
      displayedFiles: 2,
      configuredFileLimit: 2,
      snippetLineLimit: 6,
      configuredSnippetLineLimit: 6,
      snippetFilesTruncated: 1,
      compactionApplied: true,
      generatedFilesTotal: 1,
      generatedFilesDisplayed: 1,
      fileUsages: [
        .init(
          path: "Sources/App/View.swift",
          kind: GitChangeKind.modified.description,
          location: .staged,
          lineCount: 8,
          tokenEstimate: 40,
          isGenerated: false,
          isBinary: false,
          snippetTruncated: false,
          usedFullSnippet: true
        )
      ],
      remainderCount: 0,
      remainderAdditions: 0,
      remainderDeletions: 0,
      remainderGeneratedCount: 0,
      remainderKindBreakdown: [],
      remainderHintLimit: 0,
      remainderHintFiles: [],
      remainderNonGeneratedCount: 0
    )

    let batch = GenerationReport.BatchInfo(
      index: 0,
      fileCount: 1,
      filePaths: ["Sources/App/View.swift"],
      exceedsBudget: false,
      promptDiagnostics: diagnostics,
      draft: CommitDraft(subject: "Add view", body: "Details")
    )

    let report = GenerationReport(
      mode: .batched,
      finalPromptDiagnostics: diagnostics,
      batches: [batch]
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let data = try encoder.encode(report)

    guard let topLevel = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      Issue.record("Encoded report is not a JSON object")
      return
    }

    #expect(topLevel["mode"] as? String == "batched")

    let batches = topLevel["batches"] as? [[String: Any]]
    #expect(batches?.count == 1)

    let firstBatch = batches?.first
    #expect(firstBatch?["fileCount"] as? Int == 1)
    #expect(firstBatch?["exceedsBudget"] as? Bool == false)

    let filePaths = firstBatch?["filePaths"] as? [String]
    #expect(filePaths == ["Sources/App/View.swift"])

    let batchDiagnostics = firstBatch?["promptDiagnostics"] as? [String: Any]
    #expect(batchDiagnostics?["estimatedTokenCount"] as? Int == 120)

    let usages = batchDiagnostics?["fileUsages"] as? [[String: Any]]
    let firstUsage = usages?.first
    #expect(firstUsage?["usedFullSnippet"] as? Bool == true)
  }
}
