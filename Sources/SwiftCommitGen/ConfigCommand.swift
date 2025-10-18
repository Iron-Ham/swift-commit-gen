import ArgumentParser
import Foundation

struct ConfigCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "View or update stored defaults for swiftcommitgen."
  )

  @Flag(name: .long, help: "Display the current configuration without making changes.")
  var show: Bool = false

  @Option(name: .long, help: "Set the preferred default prompt style (summary, conventional, detailed).")
  var style: GenerateCommand.Style?

  @Flag(name: .customLong("clear-style"), help: "Remove the stored default prompt style.")
  var clearStyle: Bool = false

  @Option(name: .long, help: "Stage all files automatically when none are staged (true/false).")
  var autoStageIfClean: Bool?

  @Flag(name: .customLong("clear-auto-stage"), help: "Remove the stored auto-stage preference.")
  var clearAutoStage: Bool = false

  @Option(name: .long, help: "Run with --verbose by default (true/false).")
  var verbose: Bool?

  @Flag(name: .customLong("clear-verbose"), help: "Remove the stored verbose preference.")
  var clearVerbose: Bool = false

  @Option(name: .long, help: "Run with --quiet by default (true/false).")
  var quiet: Bool?

  @Flag(name: .customLong("clear-quiet"), help: "Remove the stored quiet preference.")
  var clearQuiet: Bool = false

  func run() throws {
    try validateOptions()

    let store = UserConfigurationStore()
    var configuration = try store.load()
    var changed = false

    if clearStyle {
      if configuration.preferredStyle != nil { changed = true }
      configuration.preferredStyle = nil
    }
    if let newStyle = style {
      configuration.preferredStyle = CommitGenOptions.PromptStyle(rawValue: newStyle.rawValue)
      changed = true
    }

    if clearAutoStage {
      if configuration.autoStageIfNoStaged != nil { changed = true }
      configuration.autoStageIfNoStaged = nil
    }
    if let autoStageSetting = autoStageIfClean {
      configuration.autoStageIfNoStaged = autoStageSetting
      changed = true
    }

    if clearVerbose {
      if configuration.defaultVerbose != nil { changed = true }
      configuration.defaultVerbose = nil
    }
    if let verboseSetting = verbose {
      configuration.defaultVerbose = verboseSetting
      changed = true
    }

    if clearQuiet {
      if configuration.defaultQuiet != nil { changed = true }
      configuration.defaultQuiet = nil
    }
    if let quietSetting = quiet {
      configuration.defaultQuiet = quietSetting
      changed = true
    }

    if changed {
      try store.save(configuration)
      print("Configuration updated at \(store.configurationLocation().path).")
    }

    if show || changed {
      printConfiguration(configuration, location: store.configurationLocation())
    } else if !changed {
      print("No configuration changes provided. Use --show to inspect current values.")
    }
  }

  private func validateOptions() throws {
    if style != nil && clearStyle {
      throw ValidationError("Cannot use --style together with --clear-style.")
    }
    if autoStageIfClean != nil && clearAutoStage {
      throw ValidationError("Cannot use --auto-stage-if-clean together with --clear-auto-stage.")
    }
    if verbose != nil && clearVerbose {
      throw ValidationError("Cannot use --verbose together with --clear-verbose.")
    }
    if quiet != nil && clearQuiet {
      throw ValidationError("Cannot use --quiet together with --clear-quiet.")
    }
  }

  private func printConfiguration(_ configuration: UserConfiguration, location: URL) {
    func formatBool(_ value: Bool?) -> String {
      switch value {
      case .some(true):
        return "true"
      case .some(false):
        return "false"
      case .none:
        return "(unset)"
      }
    }

    let styleDescription = configuration.preferredStyle?.rawValue ?? "(unset)"
    let autoStageDescription = formatBool(configuration.autoStageIfNoStaged)
    let verboseDescription = formatBool(configuration.defaultVerbose)
    let quietDescription = formatBool(configuration.defaultQuiet)

    print("Configuration file: \(location.path)")
    print("preferred-style: \(styleDescription)")
    print("auto-stage-if-clean: \(autoStageDescription)")
    print("verbose: \(verboseDescription)")
    print("quiet: \(quietDescription)")
  }
}
