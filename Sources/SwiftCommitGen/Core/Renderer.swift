import Foundation

protocol Renderer {
  func render(_ draft: CommitDraft, format: CommitGenOptions.OutputFormat)
}

struct ConsoleRenderer: Renderer {
  private let theme: ConsoleTheme

  init(theme: ConsoleTheme = ConsoleTheme.resolve(stream: .stdout)) {
    self.theme = theme
  }

  func render(_ draft: CommitDraft, format: CommitGenOptions.OutputFormat) {
    switch format {
    case .text:
      let subjectLine = theme.applying(theme.commitSubject, to: draft.subject)
      if let body = draft.body,
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        let message = "\(subjectLine)\n\n\(body)"
        print(message)
      } else {
        print(subjectLine)
      }
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
