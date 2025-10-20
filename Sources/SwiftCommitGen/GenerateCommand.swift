import ArgumentParser

/// Implements the `scg generate` subcommand that inspects the repository and
/// produces an AI-assisted commit draft.
struct GenerateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "generate",
    abstract: "Inspect the current Git repository and draft a commit message."
  )

  /// Supported render formats for the generated draft.
  enum OutputFormat: String, ExpressibleByArgument {
    case text
    case json
  }

  /// Controls how the generated draft should be rendered in the console.
  @Option(name: .long, help: "Choose the output format.")
  var format: OutputFormat = .text

  /// Automatically applies the accepted draft with `git commit` unless
  /// explicitly disabled.
  @Flag(
    name: .long,
    inversion: .prefixedNo,
    help: "Automatically commit the accepted draft (use --no-commit to skip)."
  )
  var commit: Bool = true

  /// Stages every tracked and untracked change prior to generation.
  @Flag(
    name: .long,
    help: "Stage all pending changes (including untracked) before generating."
  )
  private var stage: Bool = false

  /// Overrides any stored auto-stage preference and prevents staging.
  @Flag(name: .customLong("no-stage"), help: "Disable staging even if enabled via configuration.")
  private var noStage: Bool = false

  /// Forces verbose diagnostics, including prompt budgeting details.
  @Flag(
    name: [.customShort("v"), .long],
    help: "Print additional diagnostics and prompt budgeting details (overrides --quiet)."
  )
  private var verbose: Bool = false

  /// Explicitly disables verbose output even when the user default enables it.
  @Flag(
    name: .customLong("no-verbose"),
    help: "Disable verbose output even if configured as default."
  )
  private var noVerbose: Bool = false

  /// Suppresses routine informational logs while keeping notices and warnings.
  @Flag(
    name: [.customShort("q"), .long],
    help: "Suppress routine info output (warnings/errors still shown). Ignored if --verbose is set."
  )
  private var quiet: Bool = false

  /// Ensures quiet mode is off even when persisted in the configuration file.
  @Flag(name: .customLong("no-quiet"), help: "Disable quiet mode even if configured as default.")
  private var noQuiet: Bool = false

  /// Enables per-file prompt generation before combining the drafts.
  @Flag(
    name: .customLong("single-file"),
    help:
      "Process each file independently before combining the drafts into a single commit message."
  )
  private var singleFile: Bool = false

  /// Resolves CLI flags, merges them with persisted defaults, and executes the
  /// commit generation tool end-to-end.
  func run() async throws {
    let outputFormat = CommitGenOptions.OutputFormat(rawValue: format.rawValue) ?? .text
    let configStore = UserConfigurationStore()
    let userConfig = (try? configStore.load()) ?? UserConfiguration()

    let stagePreference: Bool?
    if stage {
      stagePreference = true
    } else if noStage {
      stagePreference = false
    } else {
      stagePreference = nil
    }

    let verbosePreference: Bool?
    if verbose {
      verbosePreference = true
    } else if noVerbose {
      verbosePreference = false
    } else {
      verbosePreference = nil
    }

    let quietPreference: Bool?
    if quiet {
      quietPreference = true
    } else if noQuiet {
      quietPreference = false
    } else {
      quietPreference = nil
    }

    let configuredGenerationMode = userConfig.defaultGenerationMode ?? .automatic
    let generationMode: CommitGenOptions.GenerationMode =
      singleFile ? .perFile : configuredGenerationMode

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
      isQuiet: effectiveQuiet,
      generationMode: generationMode
    )

    let tool = CommitGenTool(options: options)
    try await tool.run()
  }
}
