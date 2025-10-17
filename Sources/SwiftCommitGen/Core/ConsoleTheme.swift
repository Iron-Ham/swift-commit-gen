import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct ConsoleTheme {
  struct Style {
    var codes: [Int]

    func wrap(_ text: String, isEnabled: Bool) -> String {
      let prefix = self.prefix(isEnabled: isEnabled)
      guard !prefix.isEmpty else { return text }
      return "\(prefix)\(text)\u{001B}[0m"
    }

    func prefix(isEnabled: Bool) -> String {
      guard isEnabled, !codes.isEmpty else { return "" }
      return "\u{001B}[" + codes.map(String.init).joined(separator: ";") + "m"
    }
  }

  enum Stream {
    case stdout
    case stderr

    var fileHandle: FileHandle {
      switch self {
      case .stdout:
        return .standardOutput
      case .stderr:
        return .standardError
      }
    }
  }

  var isEnabled: Bool
  var infoLabel: Style
  var infoMessage: Style
  var warningLabel: Style
  var warningMessage: Style
  var errorLabel: Style
  var errorMessage: Style
  var muted: Style
  var emphasis: Style
  var path: Style
  var additions: Style
  var deletions: Style
  var metadata: Style
  var commitSubject: Style

  static func resolve(
    stream: Stream,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ConsoleTheme {
    let forceColor = environment["CLICOLOR_FORCE"].flatMap(Int.init) ?? 0
    let disableColor =
      environment["NO_COLOR"] != nil
      || (environment["CLICOLOR"].flatMap(Int.init) == 0)

    let tty = isTerminal(stream.fileHandle.fileDescriptor)
    let enabled = (forceColor > 0) || (!disableColor && tty)

    return ConsoleTheme(
      isEnabled: enabled,
      infoLabel: Style(codes: [90, 1]),
      infoMessage: Style(codes: [90]),
      warningLabel: Style(codes: [33, 1]),
      warningMessage: Style(codes: [33]),
      errorLabel: Style(codes: [31, 1]),
      errorMessage: Style(codes: [31]),
      muted: Style(codes: [90]),
      emphasis: Style(codes: [97, 1]),
      path: Style(codes: [36]),
      additions: Style(codes: [32]),
      deletions: Style(codes: [31]),
      metadata: Style(codes: [35]),
      commitSubject: Style(codes: [1])
    )
  }

  func applying(_ style: Style, to text: String) -> String {
    style.wrap(text, isEnabled: isEnabled)
  }

  private static func isTerminal(_ descriptor: Int32) -> Bool {
    #if os(Windows)
      return false
    #else
      return isatty(descriptor) != 0
    #endif
  }
}
