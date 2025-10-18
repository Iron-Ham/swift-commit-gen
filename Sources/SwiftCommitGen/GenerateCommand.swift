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

  @Option(name: .long, help: "Choose the output format.")
  var format: OutputFormat = .text

  @Flag(
    name: .long,
    inversion: .prefixedNo,
    help: "Automatically commit the accepted draft (use --no-commit to skip)."
  )
  var commit: Bool = true

  @Flag(name: .long, help: "Stage all pending changes (including untracked) before generating.")
  private var stageFlag: Bool = false

  @Flag(name: .customLong("no-stage"), help: "Disable staging even if enabled via configuration.")
  private var noStageFlag: Bool = false

  @Flag(
    name: [.customShort("v"), .long],
    help: "Print additional diagnostics and prompt budgeting details (overrides --quiet)."
  )
  private var verboseFlag: Bool = false

  @Flag(name: .customLong("no-verbose"), help: "Disable verbose output even if configured as default.")
  private var noVerboseFlag: Bool = false

  @Flag(
    name: [.customShort("q"), .long],
    help: "Suppress routine info output (warnings/errors still shown). Ignored if --verbose is set."
  )
  private var quietFlag: Bool = false

  @Flag(name: .customLong("no-quiet"), help: "Disable quiet mode even if configured as default.")
  private var noQuietFlag: Bool = false

  func run() async throws {
    let outputFormat = CommitGenOptions.OutputFormat(rawValue: format.rawValue) ?? .text
    let configStore = UserConfigurationStore()
    let userConfig = (try? configStore.load()) ?? UserConfiguration()

    let stagePreference: Bool?
    if stageFlag {
      stagePreference = true
    } else if noStageFlag {
      stagePreference = false
    } else {
      stagePreference = nil
    }

    let verbosePreference: Bool?
    if verboseFlag {
      verbosePreference = true
    } else if noVerboseFlag {
      verbosePreference = false
    } else {
      verbosePreference = nil
    }

    let quietPreference: Bool?
    if quietFlag {
      quietPreference = true
    } else if noQuietFlag {
      quietPreference = false
    } else {
      quietPreference = nil
    }

  let autoCommit = commit
  let stageAllBeforeGenerating = stagePreference ?? false
  let resolvedVerbose = verbosePreference ?? userConfig.defaultVerbose ?? false
  let resolvedQuiet = quietPreference ?? userConfig.defaultQuiet ?? false
  let effectiveQuiet = resolvedVerbose ? false : resolvedQuiet
  let configuredAutoStage = userConfig.autoStageIfNoStaged ?? false
  let autoStageIfNoStaged = stagePreference ?? configuredAutoStage

    let options = CommitGenOptions(
      outputFormat: outputFormat,
      promptStyle: .detailed,
      autoCommit: autoCommit,
      stageAllBeforeGenerating: stageAllBeforeGenerating,
      autoStageIfNoStaged: autoStageIfNoStaged,
      isVerbose: resolvedVerbose,
      isQuiet: effectiveQuiet
    )

    let tool = CommitGenTool(options: options)
    try await tool.run()
  }
}
