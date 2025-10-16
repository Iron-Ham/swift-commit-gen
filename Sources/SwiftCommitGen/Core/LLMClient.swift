import Foundation
import FoundationModels

protocol LLMClient {
  func generateCommitDraft(from prompt: PromptPackage) async throws -> CommitDraft
}

@Generable(description: "A commit for changes made in a git repository.")
struct CommitDraft: Hashable, Codable, Sendable {
  @Guide(description: "The title of a commit. It should be no longer than 50 characters and should summarize the contents of the chaneset for other developers reading the commit history.")
  var subject: String
  @Guide(description: "A detailed description of the the purposes of the changes.")
  var body: String?

  init(subject: String = "", body: String? = nil) {
    self.subject = subject
    self.body = body
  }

  var commitMessage: String {
    if let body, !body.isEmpty {
      "\(subject)\n\n\(body)"
    } else {
      subject
    }
  }

  var editorRepresentation: String {
    if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "\(subject)\n\n\(body)"
    }
    return subject
  }

  static func fromEditorContents(_ contents: String) -> CommitDraft {
    let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return CommitDraft(subject: "")
    }

    guard let firstLineBreak = trimmed.firstIndex(of: "\n") else {
      return CommitDraft(subject: String(trimmed))
    }

    let subjectSegment = trimmed[..<firstLineBreak]
    var remainder = trimmed[firstLineBreak...]
    while remainder.first == "\n" {
      remainder = remainder.dropFirst()
    }

    let subject = subjectSegment.trimmingCharacters(in: .whitespaces)
    let bodyCandidate = remainder.trimmingCharacters(in: .whitespacesAndNewlines)

    if bodyCandidate.isEmpty {
      return CommitDraft(subject: subject)
    }

    return CommitDraft(subject: subject, body: bodyCandidate)
  }
}

struct FoundationModelsClient: LLMClient {
  struct Configuration {
    var maxAttempts: Int
    var requestTimeout: TimeInterval
    var retryDelay: TimeInterval

    init(maxAttempts: Int = 3, requestTimeout: TimeInterval = 20, retryDelay: TimeInterval = 1) {
      self.maxAttempts = max(1, maxAttempts)
      self.requestTimeout = max(0, requestTimeout)
      self.retryDelay = max(0, retryDelay)
    }
  }

  private let generationOptions: GenerationOptions
  private let configuration: Configuration
  private let modelProvider: () -> SystemLanguageModel

  init(
    generationOptions: GenerationOptions = GenerationOptions(
      sampling: nil,
      temperature: 0.3,
      maximumResponseTokens: 512
    ),
    configuration: Configuration = Configuration(),
    modelProvider: @escaping () -> SystemLanguageModel = { SystemLanguageModel.default }
  ) {
    self.generationOptions = generationOptions
    self.configuration = configuration
    self.modelProvider = modelProvider
  }

  func generateCommitDraft(from prompt: PromptPackage) async throws -> CommitDraft {
    let model = modelProvider()

    guard case .available = model.availability else {
      let reason = availabilityDescription(model.availability)
      throw CommitGenError.modelUnavailable(reason: reason)
    }


    let session = LanguageModelSession(
      model: model,
      instructions: prompt.systemPrompt
    )

    let response = try await session.respond(generating: CommitDraft.self, options: generationOptions) {
      prompt.userPrompt
    }

    return response.content
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
