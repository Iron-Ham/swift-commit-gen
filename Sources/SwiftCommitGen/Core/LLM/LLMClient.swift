import Foundation
import FoundationModels

protocol LLMClient {
  func generateCommitDraft(from prompt: PromptPackage) async throws -> CommitDraft
}

struct CommitDraft {
  var subject: String
  var body: String

  init(subject: String = "", body: String = "") {
    self.subject = subject
    self.body = body
  }
}

struct FoundationModelsClient: LLMClient {
  func generateCommitDraft(from prompt: PromptPackage) async throws -> CommitDraft {
    // Phase 5 will call Apple's on-device language models here.
    _ = prompt
    return CommitDraft()
  }
}
