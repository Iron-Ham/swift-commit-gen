import FoundationModels

struct CommitGenOptions {
  enum OutputFormat: String, Codable {
    case text
    case json
  }

  enum PromptStyle: String, PromptRepresentable, Codable {
    case detailed

    var promptRepresentation: Prompt {
      Prompt { styleGuidance }
    }

    var styleGuidance: String {
      "Style: use the body for a few short sentences covering rationale and impact; separate points with sentences rather than markdown bullets."
    }
  }

  enum GenerationMode: String, Codable {
    case automatic
    case perFile
  }

  var outputFormat: OutputFormat
  var promptStyle: PromptStyle
  var autoCommit: Bool
  var stageAllBeforeGenerating: Bool
  var autoStageIfNoStaged: Bool
  var isVerbose: Bool
  var isQuiet: Bool
  var generationMode: GenerationMode
}
