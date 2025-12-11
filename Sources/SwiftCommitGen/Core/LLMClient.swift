import Foundation
import FoundationModels

/// Abstraction over the on-device language model that generates commit drafts.
protocol LLMClient {
  func generateCommitDraft(from prompt: PromptPackage) async throws -> LLMGenerationResult
  func generateOverview(from prompt: PromptPackage) async throws -> OverviewGenerationResult
}

/// Wraps a generated overview alongside diagnostics gathered during inference.
struct OverviewGenerationResult: Sendable {
  var overview: ChangesetOverview
  var diagnostics: PromptDiagnostics
}

@Generable(description: "A git commit message with subject and optional body.")
/// Model representation for the subject/body pair returned by the language model.
struct CommitDraft: Hashable, Codable, Sendable {
  @Guide(
    description: "Subject line (max 50 chars). Imperative mood: 'Add X' not 'Added X'. Describe WHAT changed."
  )
  var subject: String

  @Guide(
    description: "Optional body explaining WHY the change was made. Omit if subject is clear enough."
  )
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

/// Wraps a generated draft alongside diagnostics gathered during inference.
struct LLMGenerationResult: Sendable {
  var draft: CommitDraft
  var diagnostics: PromptDiagnostics
}

/// Concrete LLM client backed by Apple's FoundationModels framework.
struct FoundationModelsClient: LLMClient {
  /// Controls retry behavior and timeouts for generation requests.
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
      temperature: 0.4,
      maximumResponseTokens: 256
    ),
    configuration: Configuration = Configuration(),
    modelProvider: @escaping () -> SystemLanguageModel = { SystemLanguageModel.default }
  ) {
    self.generationOptions = generationOptions
    self.configuration = configuration
    self.modelProvider = modelProvider
  }

  func generateCommitDraft(from prompt: PromptPackage) async throws -> LLMGenerationResult {
    let model = modelProvider()

    guard case .available = model.availability else {
      let reason = availabilityDescription(model.availability)
      throw CommitGenError.modelUnavailable(reason: reason)
    }

    let session = LanguageModelSession(
      model: model,
      instructions: prompt.systemPrompt
    )

    var diagnostics = prompt.diagnostics
    let response = try await session.respond(
      generating: CommitDraft.self,
      options: generationOptions
    ) {
      prompt.userPrompt
    }

    let usage = analyzeTranscriptEntries(response.transcriptEntries)
    let promptTokens = usage.promptTokens
    let outputTokens = usage.outputTokens
    let totalTokens: Int?
    if let promptTokens, let outputTokens {
      totalTokens = promptTokens + outputTokens
    } else if let promptTokens {
      totalTokens = promptTokens
    } else if let outputTokens {
      totalTokens = outputTokens
    } else {
      totalTokens = nil
    }

    diagnostics.recordActualTokenUsage(
      promptTokens: promptTokens,
      outputTokens: outputTokens,
      totalTokens: totalTokens
    )

    return LLMGenerationResult(draft: response.content, diagnostics: diagnostics)
  }

  func generateOverview(from prompt: PromptPackage) async throws -> OverviewGenerationResult {
    let model = modelProvider()

    guard case .available = model.availability else {
      let reason = availabilityDescription(model.availability)
      throw CommitGenError.modelUnavailable(reason: reason)
    }

    let session = LanguageModelSession(
      model: model,
      instructions: prompt.systemPrompt
    )

    var diagnostics = prompt.diagnostics
    let response = try await session.respond(
      generating: ChangesetOverview.self,
      options: generationOptions
    ) {
      prompt.userPrompt
    }

    let usage = analyzeTranscriptEntries(response.transcriptEntries)
    let promptTokens = usage.promptTokens
    let outputTokens = usage.outputTokens
    let totalTokens: Int?
    if let promptTokens, let outputTokens {
      totalTokens = promptTokens + outputTokens
    } else if let promptTokens {
      totalTokens = promptTokens
    } else if let outputTokens {
      totalTokens = outputTokens
    } else {
      totalTokens = nil
    }

    diagnostics.recordActualTokenUsage(
      promptTokens: promptTokens,
      outputTokens: outputTokens,
      totalTokens: totalTokens
    )

    return OverviewGenerationResult(overview: response.content, diagnostics: diagnostics)
  }

  private func availabilityDescription(_ availability: SystemLanguageModel.Availability) -> String {
    switch availability {
    case .available:
      ""
    case .unavailable(let reason):
      switch reason {
      case .appleIntelligenceNotEnabled:
        "Apple Intelligence is turned off in Settings"
      case .deviceNotEligible:
        "this device does not support Apple Intelligence"
      case .modelNotReady:
        "the model is still preparing; try again later"
      @unknown default:
        String(describing: reason)
      }
    }
  }

  private func analyzeTranscriptEntries(
    _ entries: ArraySlice<FoundationModels.Transcript.Entry>
  ) -> (promptTokens: Int?, outputTokens: Int?) {
    var instructionSegments: [String] = []
    var promptSegments: [String] = []
    var responseSegments: [String] = []

    for entry in entries {
      switch entry {
      case .instructions(let instructions):
        instructionSegments.append(contentsOf: textSegments(from: instructions.segments))
      case .prompt(let prompt):
        promptSegments.append(contentsOf: textSegments(from: prompt.segments))
      case .response(let response):
        responseSegments.append(contentsOf: textSegments(from: response.segments))
      default:
        continue
      }
    }

    let hasPromptSegments = !instructionSegments.isEmpty || !promptSegments.isEmpty
    let hasResponseSegments = !responseSegments.isEmpty

    let promptTokenCount: Int?
    if hasPromptSegments {
      let instructionsCount = estimatedTokenCount(for: instructionSegments)
      let userCount = estimatedTokenCount(for: promptSegments)
      promptTokenCount = instructionsCount + userCount
    } else {
      promptTokenCount = nil
    }

    let responseTokenCount: Int?
    if hasResponseSegments {
      responseTokenCount = estimatedTokenCount(for: responseSegments)
    } else {
      responseTokenCount = nil
    }

    return (promptTokenCount, responseTokenCount)
  }

  private func estimatedTokenCount(for segments: [String]) -> Int {
    guard !segments.isEmpty else { return 0 }
    let combined = segments.joined(separator: "\n")
    return PromptDiagnostics.tokenEstimate(forCharacterCount: combined.count)
  }

  private func textSegments(from segments: [FoundationModels.Transcript.Segment]) -> [String] {
    segments.compactMap { segment in
      switch segment {
      case .text(let text):
        text.content
      case .structure(let structured):
        structured.content.jsonString
      @unknown default:
        nil
      }
    }
  }
}
