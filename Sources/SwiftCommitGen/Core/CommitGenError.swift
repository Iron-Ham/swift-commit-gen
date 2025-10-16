import Foundation

enum CommitGenError: Error {
  case gitRepositoryUnavailable
  case gitCommandFailed(message: String)
  case cleanWorkingTree
  case modelUnavailable(reason: String)
  case modelTimedOut(timeout: TimeInterval)
  case modelGenerationFailed(message: String)
  case notImplemented
}

extension CommitGenError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .gitRepositoryUnavailable:
      return "Failed to locate a Git repository in the current directory hierarchy."
    case .gitCommandFailed(let message):
      return message.isEmpty ? "Git command failed for an unknown reason." : message
    case .cleanWorkingTree:
      return "No pending changes detected; nothing to summarize."
    case .modelUnavailable(let reason):
      if reason.isEmpty {
        return "Apple's on-device language model is unavailable on this machine."
      }
      return "Apple's on-device language model is unavailable: \(reason)."
    case .modelTimedOut(let timeout):
      return "The on-device language model did not respond within \(formatSeconds(timeout)). Try again shortly or reduce the diff size."
    case .modelGenerationFailed(let message):
      return message
    case .notImplemented:
      return "Commit generation is not implemented yet; future phases will add this capability."
    }
  }
}

private func formatSeconds(_ timeout: TimeInterval) -> String {
  let clamped = max(0, timeout)
  let rounded = clamped.rounded(.towardZero)
  if abs(clamped - rounded) < 0.05 {
    return "\(Int(rounded))s"
  }
  return String(format: "%.1fs", clamped)
}
