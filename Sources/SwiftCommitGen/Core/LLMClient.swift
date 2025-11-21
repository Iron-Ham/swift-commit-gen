import Foundation
#if canImport(FoundationModels)
@_weakLinked import FoundationModels
#endif

/// Abstraction over the on-device language model that generates commit drafts.
protocol LLMClient {
  func generateCommitDraft(from prompt: PromptPackage) async throws -> LLMGenerationResult
}

#if canImport(FoundationModels)
@Generable(description: "A commit for changes made in a git repository.")
#endif
/// Model representation for the subject/body pair returned by the language model.
struct CommitDraft: Hashable, Codable, Sendable {
  #if canImport(FoundationModels)
  @Guide(
    description:
      "The title of a commit. It should be no longer than 50 characters and should summarize the contents of the changeset for other developers reading the commit history. It should describe WHAT was changed."
  )
  #endif
  var subject: String

  #if canImport(FoundationModels)
  @Guide(description: "A detailed description of the the purposes of the changes. It should describe WHY the changes were made.")
  #endif
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

#if canImport(FoundationModels)
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
#endif

/// Concrete LLM client backed by Ollama API.
struct OllamaClient: LLMClient {
  struct Configuration {
    var model: String
    var baseURL: String
    var temperature: Double
    var maxTokens: Int
    var logger: CommitGenLogger? 
    
    init(
      model: String = "llama3.2",
      baseURL: String = "http://localhost:11434",
      temperature: Double = 0.3,
      maxTokens: Int = 512,
      logger: CommitGenLogger? = nil
    ) {
      self.model = model
      self.baseURL = baseURL
      self.temperature = temperature
      self.maxTokens = maxTokens
      self.logger = logger
    }
  }
  
  private let configuration: Configuration
  
  init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }
  
  func generateCommitDraft(from prompt: PromptPackage) async throws -> LLMGenerationResult {
    let url = URL(string: "\(configuration.baseURL)/api/chat")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    // Structure the messages properly
    let messages: [[String: String]] = [
      [
        "role": "system",
        "content": prompt.systemPrompt.content
      ],
      [
        "role": "user",
        "content": """
        \(prompt.userPrompt.content)
        
        IMPORTANT: You must respond with ONLY valid JSON in this exact format, with no additional text before or after:
        {
          "subject": "your commit title under 50 characters",
          "body": "your detailed explanation"
        }
        
        Do not include any markdown formatting, code blocks, or explanations. Just the raw JSON object.
        """
      ]
    ]
    
    let requestBody: [String: Any] = [
      "model": configuration.model,
      "messages": messages,
      "temperature": configuration.temperature,
      "stream": false,
      "format": "json",  // Request JSON format explicitly
      "options": [
        "num_predict": configuration.maxTokens
      ]
    ]
    
    // Log the request if verbose logging is enabled
    configuration.logger?.debug {
      let systemPreview = prompt.systemPrompt.content.prefix(200)
      let userPreview = prompt.userPrompt.content.prefix(800)
      return """
      📤 Ollama Request to \(configuration.model):
      ┌─ System Prompt (first 200 chars):
      │ \(systemPreview)...
      └─ User Prompt (first 800 chars):
        \(userPreview)...
      """
    }
    
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse else {
      throw CommitGenError.llmRequestFailed(reason: "Invalid response type")
    }
    
    guard httpResponse.statusCode == 200 else {
      let errorBody = String(data: data, encoding: .utf8) ?? "no error body"
      throw CommitGenError.llmRequestFailed(
        reason: "HTTP \(httpResponse.statusCode): \(errorBody)"
      )
    }
    
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    
    guard let message = json?["message"] as? [String: Any],
          let responseText = message["content"] as? String else {
      throw CommitGenError.llmRequestFailed(reason: "No message content in Ollama response")
    }
    
    // Log the response if verbose logging is enabled
    configuration.logger?.debug {
      "📥 Ollama Response: \(responseText.prefix(500))..."
    }
    
    // Parse the JSON response from the model
    let draft = try parseCommitDraft(from: responseText)
    
    // Create diagnostics
    var diagnostics = prompt.diagnostics
    
    // Calculate token usage from the response metadata if available
    let promptTokens: Int?
    let outputTokens: Int?
    
    if let promptEvalCount = json?["prompt_eval_count"] as? Int {
      promptTokens = promptEvalCount
    } else {
      promptTokens = PromptDiagnostics.tokenEstimate(
        forCharacterCount: prompt.systemPrompt.content.count + prompt.userPrompt.content.count
      )
    }
    
    if let evalCount = json?["eval_count"] as? Int {
      outputTokens = evalCount
    } else {
      outputTokens = PromptDiagnostics.tokenEstimate(forCharacterCount: responseText.count)
    }
    
    let totalTokens = (promptTokens ?? 0) + (outputTokens ?? 0)
    
    diagnostics.recordActualTokenUsage(
      promptTokens: promptTokens,
      outputTokens: outputTokens,
      totalTokens: totalTokens > 0 ? totalTokens : nil
    )
    
    return LLMGenerationResult(draft: draft, diagnostics: diagnostics)
  }
  
  private func parseCommitDraft(from responseText: String) throws -> CommitDraft {
    // Clean up the response text
    var jsonText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Remove markdown code blocks if present
    if jsonText.hasPrefix("```json") {
      jsonText = String(jsonText.dropFirst(7))
    } else if jsonText.hasPrefix("```") {
      jsonText = String(jsonText.dropFirst(3))
    }
    
    if jsonText.hasSuffix("```") {
      jsonText = String(jsonText.dropLast(3))
    }
    
    jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
    
    guard let jsonData = jsonText.data(using: .utf8) else {
      throw CommitGenError.llmRequestFailed(reason: "Could not encode response as UTF-8")
    }
    
    do {
      let decoder = JSONDecoder()
      return try decoder.decode(CommitDraft.self, from: jsonData)
    } catch {
      // Fallback: try to parse manually
      if let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
         let subject = json["subject"] as? String {
        let body = json["body"] as? String
        return CommitDraft(subject: subject, body: body)
      }
      
      throw CommitGenError.llmRequestFailed(
        reason: "Could not parse commit draft. Response was: \(jsonText)"
      )
    }
  }
}
