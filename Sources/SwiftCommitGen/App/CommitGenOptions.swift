struct CommitGenOptions {
  enum OutputFormat: String {
    case text
    case json
  }

  var includeStagedOnly: Bool
  var dryRun: Bool
  var outputFormat: OutputFormat
}
