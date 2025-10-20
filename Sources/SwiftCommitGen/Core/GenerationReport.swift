import Foundation

/// Captures diagnostics and batch metadata for a generation run.
struct GenerationReport: Encodable {
  enum Mode: String, Encodable {
    case single
    case batched
  }

  /// Details about a single prompt batch and its intermediate draft.
  struct BatchInfo: Encodable {
    var index: Int
    var fileCount: Int
    var filePaths: [String]
    var exceedsBudget: Bool
    var promptDiagnostics: PromptDiagnostics
    var draft: CommitDraft
  }

  var mode: Mode
  var finalPromptDiagnostics: PromptDiagnostics
  var batches: [BatchInfo]
}
