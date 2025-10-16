import Foundation

struct CommitGenLogger {
  enum Level: String {
    case info
    case warning
    case error
  }

  private let theme: ConsoleTheme

  init(theme: ConsoleTheme = ConsoleTheme.resolve(stream: .stderr)) {
    self.theme = theme
  }

  func log(_ message: String, level: Level = .info) {
    let labelStyle: ConsoleTheme.Style
    let messageStyle: ConsoleTheme.Style

    switch level {
    case .info:
      labelStyle = theme.infoLabel
      messageStyle = theme.infoMessage
    case .warning:
      labelStyle = theme.warningLabel
      messageStyle = theme.warningMessage
    case .error:
      labelStyle = theme.errorLabel
      messageStyle = theme.errorMessage
    }

    let label = theme.applying(labelStyle, to: "[\(level.rawValue.uppercased())]")
    let styledMessage: String
    let messagePrefix = messageStyle.prefix(isEnabled: theme.isEnabled)
    if messagePrefix.isEmpty {
      styledMessage = message
    } else {
      let reset = "\u{001B}[0m"
      let reenabled = message.replacingOccurrences(of: reset, with: reset + messagePrefix)
      styledMessage = "\(messagePrefix)\(reenabled)\(reset)"
    }
    let output = "\(label) \(styledMessage)\n"
    if let data = output.data(using: .utf8) {
      FileHandle.standardError.write(data)
    }
  }

  func info(_ message: String) {
    log(message, level: .info)
  }

  func warning(_ message: String) {
    log(message, level: .warning)
  }

  func error(_ message: String) {
    log(message, level: .error)
  }

  func applying(_ style: ConsoleTheme.Style, to text: String) -> String {
    theme.applying(style, to: text)
  }

  var consoleTheme: ConsoleTheme {
    theme
  }
}
