import Foundation

protocol Renderer {
  func render(_ draft: CommitDraft, format: CommitGenOptions.OutputFormat)
}

struct ConsoleRenderer: Renderer {
  func render(_ draft: CommitDraft, format: CommitGenOptions.OutputFormat) {
    switch format {
    case .text:
      print(draft.subject)
      if !draft.body.isEmpty {
        print()
        print(draft.body)
      }
    case .json:
      let payload: [String: String] = [
        "subject": draft.subject,
        "body": draft.body,
      ]
      if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
        let output = String(data: data, encoding: .utf8)
      {
        print(output)
      }
    }
  }
}
