import FoundationModels

struct CommitGenOptions {
  enum OutputFormat: String {
    case text
    case json
  }

  enum PromptStyle: String, PromptRepresentable {
    case summary
    case conventional
    case detailed

    var promptRepresentation: Prompt {
      switch self {
      case .summary:
        "Style: keep the body empty when the subject fully captures the change; avoid markdown or bullet lists."
      case .conventional:
        "Style: use Conventional Commit syntax for the subject (type: summary) within 50 characters; keep any body content to short plain sentences without markdown."
      case .detailed:
        "Style: use the body for a few short sentences covering rationale and impact; separate points with sentences rather than markdown bullets."
      }
    }
  }

  var outputFormat: OutputFormat
  var promptStyle: PromptStyle
  var autoCommit: Bool
  var stageAllBeforeGenerating: Bool
  var isVerbose: Bool
  var isQuiet: Bool
}
