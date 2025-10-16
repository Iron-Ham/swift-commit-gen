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

  init(responseText: String) {
    let normalized = responseText.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

    guard let firstLine = lines.first else {
      self.subject = ""
      self.body = ""
      return
    }

    let trimmedSubject = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

    var bodyLines = Array(lines.dropFirst())
    while let head = bodyLines.first, head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      bodyLines.removeFirst()
    }
    while let tail = bodyLines.last, tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      bodyLines.removeLast()
    }

    subject = trimmedSubject
    body = bodyLines.joined(separator: "\n")
  }

  var commitMessage: String {
    if body.isEmpty {
      return subject
    }
    return "\(subject)\n\n\(body)"
  }
}

struct FoundationModelsClient: LLMClient {
  private let generationOptions: GenerationOptions

  init(
    generationOptions: GenerationOptions = GenerationOptions(
      sampling: nil,
      temperature: 0.3,
      maximumResponseTokens: 512
    )
  ) {
    self.generationOptions = generationOptions
  }

  func generateCommitDraft(from prompt: PromptPackage) async throws -> CommitDraft {
    let model = SystemLanguageModel.default

    guard case .available = model.availability else {
      let reason = availabilityDescription(model.availability)
      throw CommitGenError.modelUnavailable(reason: reason)
    }

    let instructions = prompt.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let session = LanguageModelSession(
      model: model,
      instructions: instructions.isEmpty ? nil : instructions
    )

    let response = try await session.respond(
      to: prompt.userPrompt,
      options: generationOptions
    )

    return CommitDraft(responseText: response.content)
  }

  private func availabilityDescription(_ availability: SystemLanguageModel.Availability) -> String {
    switch availability {
    case .available:
      return ""
    case .unavailable(let reason):
      switch reason {
      case .appleIntelligenceNotEnabled:
        return "Apple Intelligence is turned off in Settings"
      case .deviceNotEligible:
        return "this device does not support Apple Intelligence"
      case .modelNotReady:
        return "the model is still preparing; try again later"
      @unknown default:
        return String(describing: reason)
      }
    }
  }
}
