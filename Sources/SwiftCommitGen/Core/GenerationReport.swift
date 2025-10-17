import Foundation

struct GenerationReport: Encodable {
  enum Mode: String, Encodable {
    case single
    case batched
  }

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
