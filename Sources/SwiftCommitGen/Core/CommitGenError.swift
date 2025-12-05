import Foundation

/// Tracks the top-level failure cases that can surface during commit generation.
enum CommitGenError: Error {
  case gitRepositoryUnavailable
  case gitCommandFailed(message: String)
  case cleanWorkingTree
  case modelUnavailable(reason: String)
  case modelTimedOut(timeout: TimeInterval)
  case modelGenerationFailed(message: String)
  case llmRequestFailed(reason: String)
  case invalidBackend(String)
  case notImplemented
}

extension CommitGenError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .gitRepositoryUnavailable:
      "Failed to locate a Git repository in the current directory hierarchy."
    case .gitCommandFailed(let message):
      message.isEmpty ? "Git command failed for an unknown reason." : message
    case .cleanWorkingTree:
      "No pending changes detected; nothing to summarize."
    case .modelUnavailable(let reason):
      if reason.isEmpty {
        "Apple's on-device language model is unavailable on this machine."
      } else {
        "Apple's on-device language model is unavailable: \(reason)."
      }
    case .modelTimedOut(let timeout):
      "The on-device language model did not respond within \(formatSeconds(timeout)). Try again shortly or reduce the diff size."
    case .modelGenerationFailed(let message):
      message
    case .llmRequestFailed(let reason):
      "LLM request failed: \(reason)"
    case .invalidBackend(let message):
      message
    case .notImplemented:
      "Commit generation is not implemented yet; future phases will add this capability."
    }
  }
}

private func formatSeconds(_ timeout: TimeInterval) -> String {
  let clamped = max(0, timeout)
  let rounded = clamped.rounded(.towardZero)
  if abs(clamped - rounded) < 0.05 {
    return "\(Int(rounded))s"
  } else {
    return String(format: "%.1fs", clamped)
  }
}
