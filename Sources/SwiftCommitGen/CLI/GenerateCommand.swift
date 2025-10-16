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

  @Flag(name: [.customShort("s"), .long], help: "Only consider staged changes.")
  var stagedOnly: Bool = false

  @Flag(name: .shortAndLong, help: "Skip committing; print the generated draft to the console.")
  var dryRun: Bool = false

  @Option(name: .long, help: "Choose the output format.")
  var format: OutputFormat = .text

  func run() async throws {
    let outputFormat = CommitGenOptions.OutputFormat(rawValue: format.rawValue) ?? .text
    let options = CommitGenOptions(
      includeStagedOnly: stagedOnly,
      dryRun: dryRun,
      outputFormat: outputFormat
    )

    let tool = CommitGenTool(options: options)
    try await tool.run()
  }
}
