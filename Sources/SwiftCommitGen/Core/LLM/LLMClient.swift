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
    var subjectCandidate = CommitDraft.stripLabel(from: trimmedSubject)
    if subjectCandidate.isEmpty {
      subjectCandidate = trimmedSubject
    }

    subject = subjectCandidate
    body = CommitDraft.sanitizeBody(Array(lines.dropFirst()), subject: subjectCandidate)
  }

  var commitMessage: String {
    if body.isEmpty {
      return subject
    }
    return "\(subject)\n\n\(body)"
  }

  private static let labelPrefixes: [String] = [
    "subject:",
    "title:",
    "commit message:",
    "commit:"
  ]

  private static func stripLabel(from line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = trimmed.lowercased()

    for prefix in labelPrefixes {
      if lowercased.hasPrefix(prefix) {
        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        return trimmed[startIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    return trimmed
  }

  private static func sanitizeBody(_ bodyLines: [Substring], subject: String) -> String {
    var lines = bodyLines.map { String($0) }

    func trimmed(_ string: String) -> String {
      string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    while let first = lines.first, trimmed(first).isEmpty {
      lines.removeFirst()
    }
    while let last = lines.last, trimmed(last).isEmpty {
      lines.removeLast()
    }

    if let first = lines.first, trimmed(first).hasPrefix("```") {
      lines.removeFirst()
    }
    if let last = lines.last, trimmed(last).hasPrefix("```") {
      lines.removeLast()
    }

    while let first = lines.first, trimmed(first).isEmpty {
      lines.removeFirst()
    }
    while let last = lines.last, trimmed(last).isEmpty {
      lines.removeLast()
    }

    while let first = lines.first {
      let trimmedFirst = trimmed(first)
      let strippedFirst = stripLabel(from: trimmedFirst)
      if trimmedFirst.caseInsensitiveCompare(subject) == .orderedSame
        || strippedFirst.caseInsensitiveCompare(subject) == .orderedSame
      {
        lines.removeFirst()
        continue
      }
      break
    }

    while let last = lines.last {
      let trimmedLast = trimmed(last)
      let strippedLast = stripLabel(from: trimmedLast)
      if trimmedLast.caseInsensitiveCompare(subject) == .orderedSame
        || strippedLast.caseInsensitiveCompare(subject) == .orderedSame
      {
        lines.removeLast()
        continue
      }
      break
    }

    let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

    if body.isEmpty {
      return ""
    }

    if body.caseInsensitiveCompare(subject) == .orderedSame {
      return ""
    }

    let strippedBody = stripLabel(from: body)
    if strippedBody.caseInsensitiveCompare(subject) == .orderedSame {
      return ""
    }

    for suffix in [".", "!", "?"] {
      if (subject + suffix).caseInsensitiveCompare(body) == .orderedSame {
        return ""
      }
    }

    return body
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
  private let retryHandler: AsyncRetryHandler

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
    self.retryHandler = AsyncRetryHandler(
      maxAttempts: configuration.maxAttempts,
      requestTimeout: configuration.requestTimeout,
      retryDelay: configuration.retryDelay
    )
  }

  func generateCommitDraft(from prompt: PromptPackage) async throws -> CommitDraft {
    let model = modelProvider()

    guard case .available = model.availability else {
      let reason = availabilityDescription(model.availability)
      throw CommitGenError.modelUnavailable(reason: reason)
    }

    let instructions = prompt.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let session = DefaultLanguageModelSession(
      session: LanguageModelSession(
        model: model,
        instructions: instructions.isEmpty ? nil : instructions
      )
    )
    let userPrompt = prompt.userPrompt
    let options = generationOptions

    let responseText = try await retryHandler.execute {
      try await session.respond(to: userPrompt, options: options)
    }

    return CommitDraft(responseText: responseText)
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

private protocol LanguageModelSessionType: Sendable {
  func respond(to prompt: String, options: GenerationOptions) async throws -> String
}

private struct DefaultLanguageModelSession: LanguageModelSessionType {
  private let session: LanguageModelSession

  init(session: LanguageModelSession) {
    self.session = session
  }

  func respond(to prompt: String, options: GenerationOptions) async throws -> String {
    let response = try await session.respond(to: prompt, options: options)
    return response.content
  }
}

extension DefaultLanguageModelSession: @unchecked Sendable {}

struct AsyncRetryHandler {
  private let maxAttempts: Int
  private let requestTimeout: TimeInterval
  private let retryDelay: TimeInterval

  init(maxAttempts: Int, requestTimeout: TimeInterval, retryDelay: TimeInterval) {
    self.maxAttempts = max(1, maxAttempts)
    self.requestTimeout = max(0, requestTimeout)
    self.retryDelay = max(0, retryDelay)
  }

  func execute<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        let result = try await runWithTimeout(operation)
        return result
      } catch is RequestTimeoutError {
        lastError = CommitGenError.modelTimedOut(timeout: requestTimeout)
      } catch {
        lastError = error
      }

      if attempt < maxAttempts && retryDelay > 0 {
        try await Task.sleep(nanoseconds: nanoseconds(for: retryDelay))
      }
    }

    if let commitError = lastError as? CommitGenError {
      throw commitError
    }

    throw CommitGenError.modelGenerationFailed(
      message: fallbackMessage(from: lastError)
    )
  }

  private func runWithTimeout<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    if requestTimeout <= 0 {
      return try await operation()
    }

    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try Task.checkCancellation()
        return try await operation()
      }

      group.addTask {
        let nanos = nanoseconds(for: requestTimeout)
        if nanos > 0 {
          try await Task.sleep(nanoseconds: nanos)
        }
        throw RequestTimeoutError()
      }

      do {
        if let result = try await group.next() {
          group.cancelAll()
          return result
        }
        throw RequestTimeoutError()
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  private func fallbackMessage(from error: Error?) -> String {
    let reason: String
    if let commitError = error as? CommitGenError,
      let description = commitError.errorDescription,
      !description.isEmpty
    {
      reason = description
    } else if let localized = (error as? LocalizedError)?.errorDescription,
      !localized.isEmpty
    {
      reason = localized
    } else if let error {
      let description = String(describing: error)
      reason = description.isEmpty ? "an unknown error occurred" : description
    } else {
      reason = "an unknown error occurred"
    }

    return
      "Failed to generate a commit draft after \(maxAttempts) attempt(s): \(reason). Try again shortly or craft the commit message manually."
  }
}

private struct RequestTimeoutError: Error {}

private func nanoseconds(for seconds: TimeInterval) -> UInt64 {
  guard seconds > 0 else { return 0 }
  let value = seconds * 1_000_000_000
  if value >= Double(UInt64.max) {
    return UInt64.max
  }
  return UInt64(value)
}
