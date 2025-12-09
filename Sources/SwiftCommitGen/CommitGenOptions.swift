import FoundationModels

/// Configuration for git diff command behavior.
struct DiffOptions: Codable, Hashable {
  /// Include entire functions containing changes for better semantic context.
  var useFunctionContext: Bool = true
  /// Detect renamed and copied files rather than showing as delete + add.
  var detectRenamesCopies: Bool = true
  /// Number of context lines around changes. Uses git default (3) when nil.
  var contextLines: Int? = nil

  static let `default` = DiffOptions()
}

/// Container for the resolved configuration driving a commit generation run.
struct CommitGenOptions {
  /// Supported output formats for the rendered draft.
  enum OutputFormat: String, Codable {
    case text
    case json
  }

  /// Available prompt styles that influence how instructions are sent to the model.
  enum PromptStyle: String, PromptRepresentable, Codable {
    case detailed

    var promptRepresentation: Prompt {
      Prompt { styleGuidance }
    }

    var styleGuidance: String {
      "Style: use the body for a few short sentences covering rationale and impact; separate points with sentences rather than markdown bullets."
    }
  }

  /// Strategies for how the tool should build prompts from repository changes.
  enum GenerationMode: String, Codable {
    case automatic
    case perFile
  }

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
  /// Configuration for git diff command behavior.
  var diffOptions: DiffOptions
}
