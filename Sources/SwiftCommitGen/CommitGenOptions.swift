#if canImport(FoundationModels)
  @_weakLinked import FoundationModels
#endif

/// Container for the resolved configuration driving a commit generation run.
struct CommitGenOptions {
  /// Supported LLM providers for commit generation.
  enum LLMProvider: Codable, Equatable {
    case foundationModels
    case ollama(model: String, baseURL: String)
  }

  /// Supported output formats for the rendered draft.
  enum OutputFormat: String, Codable {
    case text
    case json
  }

  /// Available prompt styles that influence how instructions are sent to the model.
  enum PromptStyle: String, Codable {
    case detailed

    #if canImport(FoundationModels)
      var promptRepresentation: Prompt {
        Prompt { styleGuidance }
      }
    #endif

    var styleGuidance: String {
      "Style: use the body for a few short sentences covering rationale and impact; separate points with sentences rather than markdown bullets."
    }
  }

  /// Strategies for how the tool should build prompts from repository changes.
  enum GenerationMode: String, Codable {
    case automatic
    case perFile
  }

  /// LLM provider to use for commit generation.
  var llmProvider: LLMProvider
  /// Desired format for logging or piping the generated draft.
  var outputFormat: OutputFormat
  /// Prompt template variant to use when communicating with the model.
  var promptStyle: PromptStyle
  /// Indicates whether the tool should call `git commit` after acceptance.
  var autoCommit: Bool
  /// Forces a blanket `git add --all` before summarizing changes.
  var stageAllBeforeGenerating: Bool
  /// Automatically stages pending changes when the staging area starts empty.
  var autoStageIfNoStaged: Bool
  /// Toggles high-verbosity diagnostics for debugging and prompt budgets.
  var isVerbose: Bool
  /// Hides non-essential informational logs.
  var isQuiet: Bool
  /// Controls whether batching happens automatically or per file.
  var generationMode: GenerationMode
}
