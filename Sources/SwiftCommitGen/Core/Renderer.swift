import Foundation

protocol Renderer {
  func render(_ draft: CommitDraft, format: CommitGenOptions.OutputFormat)
}

struct ConsoleRenderer: Renderer {
  func render(_ draft: CommitDraft, format: CommitGenOptions.OutputFormat) {
    switch format {
    case .text:
      print(draft.commitMessage)
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let data = try? encoder.encode(draft),
        let output = String(data: data, encoding: .utf8)
      {
        print(output)
      }
    }
  }
}
