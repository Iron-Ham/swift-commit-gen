import Foundation

enum CommitGenError: Error {
  case gitRepositoryUnavailable
  case gitCommandFailed(message: String)
  case cleanWorkingTree
  case modelUnavailable
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
    case .modelUnavailable:
      return "Apple's on-device language model is unavailable on this machine."
    case .notImplemented:
      return "Commit generation is not implemented yet; future phases will add this capability."
    }
  }
}
