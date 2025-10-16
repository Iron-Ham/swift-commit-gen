struct CommitGenOptions {
  enum OutputFormat: String {
    case text
    case json
  }

  enum PromptStyle: String {
    case summary
    case conventional
    case detailed
  }

  var includeStagedOnly: Bool
  var dryRun: Bool
  var outputFormat: OutputFormat
  var promptStyle: PromptStyle
  var autoCommit: Bool
  var stageChanges: Bool
}
