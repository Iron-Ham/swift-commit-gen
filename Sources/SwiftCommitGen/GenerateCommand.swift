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

  @Flag(name: .long, help: "Stage all pending changes (including untracked) before generating.")
  var stage: Bool = false

  @Flag(
    name: [.customShort("v"), .long],
    help: "Print additional diagnostics and prompt budgeting details (overrides --quiet)."
  )
  var verbose: Bool = false

  @Flag(
    name: [.customShort("q"), .long],
    help: "Suppress routine info output (warnings/errors still shown). Ignored if --verbose is set."
  )
  var quiet: Bool = false

  func run() async throws {
    let outputFormat = CommitGenOptions.OutputFormat(rawValue: format.rawValue) ?? .text
    let promptStyle = CommitGenOptions.PromptStyle(rawValue: style.rawValue) ?? .summary
    let autoCommit = commit
    let stageAllBeforeGenerating = stage

    let effectiveQuiet = verbose ? false : quiet
    let options = CommitGenOptions(
      outputFormat: outputFormat,
      promptStyle: promptStyle,
      autoCommit: autoCommit,
      stageAllBeforeGenerating: stageAllBeforeGenerating,
      isVerbose: verbose,
      isQuiet: effectiveQuiet
    )

    let tool = CommitGenTool(options: options)
    try await tool.run()
  }
}
