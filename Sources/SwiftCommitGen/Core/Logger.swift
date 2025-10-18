import Foundation

struct CommitGenLogger {
  enum Level: String {
    case debug
    case info
    case notice
    case warning
    case error
  }

  private let theme: ConsoleTheme
  private let isVerbose: Bool
  private let isQuiet: Bool
  private let fileHandle: FileHandle

  init(
    theme: ConsoleTheme = ConsoleTheme.resolve(stream: .stderr),
    isVerbose: Bool = false,
    isQuiet: Bool = false,
    fileHandle: FileHandle = .standardError
  ) {
    self.theme = theme
    self.isVerbose = isVerbose
    self.isQuiet = isQuiet
    self.fileHandle = fileHandle
  }

  func log(_ message: String, level: Level = .info) {
    if level == .debug && !isVerbose { return }
    if level == .info && isQuiet && !isVerbose { return }

    let labelStyle: ConsoleTheme.Style
    let messageStyle: ConsoleTheme.Style

    switch level {
    case .debug:
      labelStyle = theme.muted
      messageStyle = theme.muted
    case .info:
      labelStyle = theme.infoLabel
      messageStyle = theme.infoMessage
    case .notice:
      labelStyle = theme.emphasis
      messageStyle = theme.infoMessage
    case .warning:
      labelStyle = theme.warningLabel
      messageStyle = theme.warningMessage
    case .error:
      labelStyle = theme.errorLabel
      messageStyle = theme.errorMessage
    }

    let label: String? =
      isVerbose ? theme.applying(labelStyle, to: "[\(level.rawValue.uppercased())]") : nil
    let styledMessage: String
    let messagePrefix = messageStyle.prefix(isEnabled: theme.isEnabled)
    if messagePrefix.isEmpty {
      styledMessage = message
    } else {
      let reset = "\u{001B}[0m"
      let reenabled = message.replacingOccurrences(of: reset, with: reset + messagePrefix)
      styledMessage = "\(messagePrefix)\(reenabled)\(reset)"
    }
    let output: String
    if let label {
      output = "\(label) \(styledMessage)\n"
    } else {
      output = "\(styledMessage)\n"
    }
    if let data = output.data(using: .utf8) {
      fileHandle.write(data)
    }
  }

  // MARK: - Convenience APIs

  func debug(_ message: @autoclosure () -> String) { log(message(), level: .debug) }
  func debug(_ build: () -> String) { if isVerbose { log(build(), level: .debug) } }
  func info(_ message: String) { log(message, level: .info) }
  func notice(_ message: String) { log(message, level: .notice) }
  func warning(_ message: String) { log(message, level: .warning) }
  func error(_ message: String) { log(message, level: .error) }

  // MARK: - Styling helpers
  func applying(_ style: ConsoleTheme.Style, to text: String) -> String {
    theme.applying(style, to: text)
  }
  var consoleTheme: ConsoleTheme { theme }

  var isVerboseEnabled: Bool { isVerbose }
  var isQuietEnabled: Bool { isQuiet } 
}
