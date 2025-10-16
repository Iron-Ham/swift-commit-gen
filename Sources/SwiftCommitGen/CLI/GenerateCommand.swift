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

  @Flag(name: .shortAndLong, help: "Skip committing; print the generated draft to the console.")
  var dryRun: Bool = false

  @Option(name: .long, help: "Choose the output format.")
  var format: OutputFormat = .text

  @Option(name: .long, help: "Choose the prompt style (summary, conventional, detailed).")
  var style: Style = .summary

  @Flag(name: .long, help: "Automatically commit the accepted draft.")
  var commit: Bool = false

  @Flag(name: .long, help: "Stage summarized changes before committing (implies --commit).")
  var stage: Bool = false

  func run() async throws {
    let outputFormat = CommitGenOptions.OutputFormat(rawValue: format.rawValue) ?? .text
    let promptStyle = CommitGenOptions.PromptStyle(rawValue: style.rawValue) ?? .summary
    let autoCommit = commit || stage
    let stageChanges = autoCommit && stage

    let options = CommitGenOptions(
      includeStagedOnly: stagedOnly,
      dryRun: dryRun,
      outputFormat: outputFormat,
      promptStyle: promptStyle,
      autoCommit: autoCommit,
      stageChanges: stageChanges
    )

    let tool = CommitGenTool(options: options)
    try await tool.run()
  }
}
