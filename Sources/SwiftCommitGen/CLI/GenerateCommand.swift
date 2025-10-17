import ArgumentParser

struct GenerateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "generate",
    abstract: "Inspect the current Git repository and draft a commit message."
  )

  enum OutputFormat: String, ExpressibleByArgument {
    case text
    case json
  }

  enum Style: String, ExpressibleByArgument {
    case summary
    case conventional
    case detailed
  }

  @Flag(name: [.customShort("s"), .long], help: "Only consider staged changes.")
  var stagedOnly: Bool = false

  @Option(name: .long, help: "Choose the output format.")
  var format: OutputFormat = .text

  @Option(name: .long, help: "Choose the prompt style (summary, conventional, detailed).")
  var style: Style = .summary

  @Flag(
    name: .long,
    inversion: .prefixedNo,
    help: "Automatically commit the accepted draft (use --no-commit to skip)."
  )
  var commit: Bool = true

  @Flag(
    name: .long,
    inversion: .prefixedNo,
    help: "Stage summarized changes before committing (use --no-stage to opt out)."
  )
  var stage: Bool = true

  @Flag(name: [.customShort("v"), .long], help: "Print additional diagnostics and prompt budgeting details.")
  var verbose: Bool = false

  func run() async throws {
    let outputFormat = CommitGenOptions.OutputFormat(rawValue: format.rawValue) ?? .text
    let promptStyle = CommitGenOptions.PromptStyle(rawValue: style.rawValue) ?? .summary
  let autoCommit = commit
  let stageChanges = autoCommit && stage

    let options = CommitGenOptions(
      includeStagedOnly: stagedOnly,
      outputFormat: outputFormat,
      promptStyle: promptStyle,
      autoCommit: autoCommit,
      stageChanges: stageChanges,
      isVerbose: verbose
    )

    let tool = CommitGenTool(options: options)
    try await tool.run()
  }
}
