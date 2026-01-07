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
struct FoundationModelsClient: LLMClient, Sendable {
  /// Controls retry behavior and timeouts for generation requests.
  struct Configuration: Sendable {
    var maxAttempts: Int
    var requestTimeout: TimeInterval
    var retryDelay: TimeInterval

    init(maxAttempts: Int = 3, requestTimeout: TimeInterval = 30, retryDelay: TimeInterval = 1) {
      self.maxAttempts = max(1, maxAttempts)
      self.requestTimeout = max(1, requestTimeout)
      self.retryDelay = max(0, retryDelay)
    }
  }

  /// Holds extracted Sendable data from a LanguageModelSession response.
  private struct ResponseData<Content: Sendable>: Sendable {
    let content: Content
    let promptTokens: Int?
    let outputTokens: Int?
  }

  private let generationOptions: GenerationOptions
  private let configuration: Configuration
  private let modelProvider: @Sendable () -> SystemLanguageModel

  init(
    generationOptions: GenerationOptions = GenerationOptions(
      sampling: nil,
      temperature: 0.4,
      maximumResponseTokens: 256
    ),
    configuration: Configuration = Configuration(),
    modelProvider: @escaping @Sendable () -> SystemLanguageModel = { SystemLanguageModel.default }
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

    var lastError: Error?
    var diagnostics = prompt.diagnostics

    // Capture values needed inside the Sendable closure
    let options = generationOptions
    let systemPrompt = prompt.systemPrompt
    let userPrompt = prompt.userPrompt

    for attempt in 1...configuration.maxAttempts {
      // Exponential backoff: timeout doubles each retry (30s → 60s → 120s)
      let attemptTimeout = configuration.requestTimeout * pow(2.0, Double(attempt - 1))

      do {
        let responseData = try await withTimeout(seconds: attemptTimeout) {
          let session = LanguageModelSession(model: model, instructions: systemPrompt)
          let response = try await session.respond(
            generating: CommitDraft.self,
            options: options
          ) {
            userPrompt
          }

          // Extract Sendable data before crossing task boundary
          let usage = Self.analyzeTranscriptEntries(response.transcriptEntries)
          return ResponseData(
            content: response.content,
            promptTokens: usage.promptTokens,
            outputTokens: usage.outputTokens
          )
        }

        let promptTokens = responseData.promptTokens
        let outputTokens = responseData.outputTokens
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

        return LLMGenerationResult(draft: responseData.content, diagnostics: diagnostics)
      } catch is LLMTimeoutError {
        lastError = CommitGenError.modelTimedOut(timeout: attemptTimeout)
        if attempt < configuration.maxAttempts {
          try await Task.sleep(for: .seconds(configuration.retryDelay))
        }
      } catch {
        // Non-timeout errors fail immediately
        throw error
      }
    }

    throw lastError ?? CommitGenError.modelTimedOut(timeout: configuration.requestTimeout)
  }

  func generateOverview(from prompt: PromptPackage) async throws -> OverviewGenerationResult {
    let model = modelProvider()

    guard case .available = model.availability else {
      let reason = availabilityDescription(model.availability)
      throw CommitGenError.modelUnavailable(reason: reason)
    }

    var lastError: Error?
    var diagnostics = prompt.diagnostics

    // Capture values needed inside the Sendable closure
    let options = generationOptions
    let systemPrompt = prompt.systemPrompt
    let userPrompt = prompt.userPrompt

    for attempt in 1...configuration.maxAttempts {
      // Exponential backoff: timeout doubles each retry (30s → 60s → 120s)
      let attemptTimeout = configuration.requestTimeout * pow(2.0, Double(attempt - 1))

      do {
        let responseData = try await withTimeout(seconds: attemptTimeout) {
          let session = LanguageModelSession(model: model, instructions: systemPrompt)
          let response = try await session.respond(
            generating: ChangesetOverview.self,
            options: options
          ) {
            userPrompt
          }

          // Extract Sendable data before crossing task boundary
          let usage = Self.analyzeTranscriptEntries(response.transcriptEntries)
          return ResponseData(
            content: response.content,
            promptTokens: usage.promptTokens,
            outputTokens: usage.outputTokens
          )
        }

        let promptTokens = responseData.promptTokens
        let outputTokens = responseData.outputTokens
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

        return OverviewGenerationResult(overview: responseData.content, diagnostics: diagnostics)
      } catch is LLMTimeoutError {
        lastError = CommitGenError.modelTimedOut(timeout: attemptTimeout)
        if attempt < configuration.maxAttempts {
          try await Task.sleep(for: .seconds(configuration.retryDelay))
        }
      } catch {
        // Non-timeout errors fail immediately
        throw error
      }
    }

    throw lastError ?? CommitGenError.modelTimedOut(timeout: configuration.requestTimeout)
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

  private static func analyzeTranscriptEntries(
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

  private static func estimatedTokenCount(for segments: [String]) -> Int {
    guard !segments.isEmpty else { return 0 }
    let combined = segments.joined(separator: "\n")
    return PromptDiagnostics.tokenEstimate(forCharacterCount: combined.count)
  }

  private static func textSegments(from segments: [FoundationModels.Transcript.Segment]) -> [String] {
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

// MARK: - Timeout Utilities

/// Sentinel error thrown when an LLM operation exceeds its time limit.
struct LLMTimeoutError: Error {}

/// Races an async operation against a timeout, throwing `LLMTimeoutError` if the timeout fires first.
///
/// Uses a task group to run the operation and a sleep task concurrently. Whichever completes
/// first determines the outcome—either returning the result or throwing the timeout error.
func withTimeout<T: Sendable>(
  seconds: TimeInterval,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw LLMTimeoutError()
    }

    // The first task to complete determines success or failure
    guard let result = try await group.next() else {
      throw LLMTimeoutError()
    }

    // Cancel the remaining task (either the operation or the sleep)
    group.cancelAll()
    return result
  }
}
