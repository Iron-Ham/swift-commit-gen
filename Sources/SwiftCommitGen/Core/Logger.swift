import Foundation

struct CommitGenLogger {

  enum Level: String {
    case info
    case warning
    case error
  }

  func log(_ message: String, level: Level = .info) {
    let output = "[\(level.rawValue.uppercased())] \(message)\n"
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
}
