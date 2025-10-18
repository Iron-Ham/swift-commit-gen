import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct ConfigCommand: ParsableCommand {

  struct Dependencies {
    var makeStore: () -> any ConfigCommandStore
    var makeIO: () -> any ConfigCommandIO

    init(
      makeStore: @escaping () -> any ConfigCommandStore = {
        UserConfigurationStoreAdapter(store: UserConfigurationStore())
      },
      makeIO: @escaping () -> any ConfigCommandIO = { TerminalConfigCommandIO() }
    ) {
      self.makeStore = makeStore
      self.makeIO = makeIO
    }
  }

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
    let dependencies = ConfigCommand.resolveDependencies()
    let store = dependencies.makeStore()
    var configuration = try store.load()
    let io = dependencies.makeIO()

    let useInteractive = shouldRunInteractively && io.isInteractive
    var changed = false

    if useInteractive {
      let result = ConfigInteractiveEditor(io: io).edit(configuration: configuration)
      configuration = result.configuration
      changed = result.changed
    } else {
      changed = applyDirectUpdates(to: &configuration)
    }

    if changed {
      try store.save(configuration)
      print("Configuration updated at \(store.configurationLocation().path).")
    } else if shouldRunInteractively && !io.isInteractive {
      print("Interactive configuration requires an interactive terminal. Pass flags to configure non-interactively.")
    }

    if useInteractive || show || changed {
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
    if let verboseSetting = verbose, let quietSetting = quiet, verboseSetting && quietSetting {
      throw ValidationError("Cannot set both --verbose true and --quiet true.")
    }
  }

  private var shouldRunInteractively: Bool {
    !show
      && style == nil
      && !clearStyle
      && autoStageIfClean == nil
      && !clearAutoStage
      && verbose == nil
      && !clearVerbose
      && quiet == nil
      && !clearQuiet
  }

  private func applyDirectUpdates(to configuration: inout UserConfiguration) -> Bool {
    var changed = false

    if clearStyle {
      if configuration.preferredStyle != nil {
        configuration.preferredStyle = nil
        changed = true
      }
    }
    if let newStyle = style {
      let next = CommitGenOptions.PromptStyle(rawValue: newStyle.rawValue)
      if configuration.preferredStyle != next {
        configuration.preferredStyle = next
        changed = true
      }
    }

    if clearAutoStage {
      if configuration.autoStageIfNoStaged != nil {
        configuration.autoStageIfNoStaged = nil
        changed = true
      }
    }
    if let autoStageSetting = autoStageIfClean {
      if configuration.autoStageIfNoStaged != autoStageSetting {
        configuration.autoStageIfNoStaged = autoStageSetting
        changed = true
      }
    }

    if clearVerbose {
      if configuration.defaultVerbose != nil {
        configuration.defaultVerbose = nil
        changed = true
      }
    }
    if let verboseSetting = verbose {
      if configuration.defaultVerbose != verboseSetting {
        configuration.defaultVerbose = verboseSetting
        changed = true
      }
      if verboseSetting && configuration.defaultQuiet != nil {
        configuration.defaultQuiet = nil
        changed = true
      }
    }

    if clearQuiet {
      if configuration.defaultQuiet != nil {
        configuration.defaultQuiet = nil
        changed = true
      }
    }
    if let quietSetting = quiet {
      if configuration.defaultQuiet != quietSetting {
        configuration.defaultQuiet = quietSetting
        changed = true
      }
      if quietSetting && configuration.defaultVerbose != nil {
        configuration.defaultVerbose = nil
        changed = true
      }
    }

    return changed
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

private enum ConfigCommandDependencyContext {
  @TaskLocal static var override: ConfigCommand.Dependencies?
}

extension ConfigCommand {
  static func withDependencies<Result>(_ dependencies: Dependencies, run operation: () throws -> Result)
    rethrows -> Result
  {
    try ConfigCommandDependencyContext.$override.withValue(dependencies) {
      try operation()
    }
  }

  static func resolveDependencies() -> Dependencies {
    ConfigCommandDependencyContext.override ?? Dependencies()
  }
}

extension ConfigCommand.Dependencies: @unchecked Sendable {}

protocol ConfigCommandStore {
  func load() throws -> UserConfiguration
  func save(_ configuration: UserConfiguration) throws
  func configurationLocation() -> URL
}

struct UserConfigurationStoreAdapter: ConfigCommandStore {
  private let store: UserConfigurationStore

  init(store: UserConfigurationStore) {
    self.store = store
  }

  func load() throws -> UserConfiguration {
    try store.load()
  }

  func save(_ configuration: UserConfiguration) throws {
    try store.save(configuration)
  }

  func configurationLocation() -> URL {
    store.configurationLocation()
  }
}

protocol ConfigCommandIO: AnyObject {
  var isInteractive: Bool { get }
  func printLine(_ text: String)
  func prompt(_ text: String) -> String?
}

final class TerminalConfigCommandIO: ConfigCommandIO {
  var isInteractive: Bool {
#if canImport(Darwin)
    return isatty(STDIN_FILENO) == 1
#elseif canImport(Glibc)
    return isatty(STDIN_FILENO) == 1
#else
    return true
#endif
  }

  func printLine(_ text: String) {
    print(text)
  }

  func prompt(_ text: String) -> String? {
    print(text, terminator: "")
    return readLine()
  }
}

struct ConfigInteractiveEditor {
  private let io: any ConfigCommandIO

  init(io: any ConfigCommandIO) {
    self.io = io
  }

  func edit(configuration: UserConfiguration)
    -> (configuration: UserConfiguration, changed: Bool)
  {
    var updated = configuration
    let original = configuration

    io.printLine("Interactive configuration editor (press Enter to keep current values).")

    if let styleChoice = promptForStyle(current: configuration.preferredStyle) {
      switch styleChoice {
      case .summary:
        updated.preferredStyle = .summary
      case .conventional:
        updated.preferredStyle = .conventional
      case .detailed:
        updated.preferredStyle = .detailed
      case .unset:
        updated.preferredStyle = nil
      }
    }

    if let autoStageChoice = promptForAutoStage(current: configuration.autoStageIfNoStaged) {
      switch autoStageChoice {
      case .enabled:
        updated.autoStageIfNoStaged = true
      case .disabled:
        updated.autoStageIfNoStaged = false
      case .unset:
        updated.autoStageIfNoStaged = nil
      }
    }

    if let verbosityChoice = promptForVerbosity(
      defaultVerbose: configuration.defaultVerbose,
      defaultQuiet: configuration.defaultQuiet
    ) {
      switch verbosityChoice {
      case .standard:
        updated.defaultVerbose = nil
        updated.defaultQuiet = nil
      case .verbose:
        updated.defaultVerbose = true
        updated.defaultQuiet = nil
      case .quiet:
        updated.defaultQuiet = true
        updated.defaultVerbose = nil
      }
    }

    let changed = updated.preferredStyle != original.preferredStyle
      || updated.autoStageIfNoStaged != original.autoStageIfNoStaged
      || updated.defaultVerbose != original.defaultVerbose
      || updated.defaultQuiet != original.defaultQuiet

    return (updated, changed)
  }

  private func promptForStyle(current: CommitGenOptions.PromptStyle?) -> StyleChoice? {
    let currentDescription = current?.rawValue ?? "(unset)"
    let choices: [Choice<StyleChoice>] = [
      Choice(label: "1", tokens: ["1", "summary", "s"], description: "summary", value: .summary),
      Choice(
        label: "2", tokens: ["2", "conventional", "c"], description: "conventional", value: .conventional
      ),
      Choice(label: "3", tokens: ["3", "detailed", "d"], description: "detailed", value: .detailed),
      Choice(label: "4", tokens: ["4", "unset", "u"], description: "unset", value: .unset),
    ]
    return promptChoice(
      title: "Preferred prompt style (current: \(currentDescription)):",
      choices: choices,
      keepMessage: "Press Enter to keep current style."
    )
  }

  private func promptForAutoStage(current: Bool?) -> AutoStageChoice? {
    let currentDescription: String
    switch current {
    case .some(true):
      currentDescription = "enabled"
    case .some(false):
      currentDescription = "disabled"
    case .none:
      currentDescription = "(unset)"
    }

    let choices: [Choice<AutoStageChoice>] = [
      Choice(label: "1", tokens: ["1", "yes", "y"], description: "enable", value: .enabled),
      Choice(label: "2", tokens: ["2", "no", "n"], description: "disable", value: .disabled),
      Choice(label: "3", tokens: ["3", "unset", "u"], description: "unset", value: .unset),
    ]

    return promptChoice(
      title: "Automatically stage files when none are staged (current: \(currentDescription)):",
      choices: choices,
      keepMessage: "Press Enter to keep current auto-stage preference."
    )
  }

  private func promptForVerbosity(defaultVerbose: Bool?, defaultQuiet: Bool?) -> VerbosityChoice? {
    let currentChoice: VerbosityChoice
    if defaultVerbose == true {
      currentChoice = .verbose
    } else if defaultQuiet == true {
      currentChoice = .quiet
    } else {
      currentChoice = .standard
    }

    let description: String
    switch currentChoice {
    case .standard:
      description = "standard"
    case .verbose:
      description = "verbose"
    case .quiet:
      description = "quiet"
    }

    let choices: [Choice<VerbosityChoice>] = [
      Choice(label: "1", tokens: ["1", "standard", "s"], description: "standard", value: .standard),
      Choice(label: "2", tokens: ["2", "verbose", "v"], description: "verbose", value: .verbose),
      Choice(label: "3", tokens: ["3", "quiet", "q"], description: "quiet", value: .quiet),
    ]

    return promptChoice(
      title: "Default verbosity (current: \(description)):",
      choices: choices,
      keepMessage: "Press Enter to keep current verbosity."
    )
  }

  private func promptChoice<Value>(
    title: String,
    choices: [Choice<Value>],
    keepMessage: String
  ) -> Value? {
    io.printLine("")
    io.printLine(title)
    for choice in choices {
      io.printLine("  \(choice.label)) \(choice.description)")
    }

    while true {
      guard let response = io.prompt("Enter choice (\(keepMessage)): ") else { return nil }
      let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return nil }
      let normalized = trimmed.lowercased()
      if let match = choices.first(where: { $0.matches(normalized) }) {
        return match.value
      }
      io.printLine("Invalid selection. Please try again.")
    }
  }

  private struct Choice<Value> {
    let label: String
    let tokens: [String]
    let description: String
    let value: Value

    func matches(_ input: String) -> Bool {
      tokens.contains(input)
    }
  }

  private enum StyleChoice {
    case summary
    case conventional
    case detailed
    case unset
  }

  private enum AutoStageChoice {
    case enabled
    case disabled
    case unset
  }

  private enum VerbosityChoice {
    case standard
    case verbose
    case quiet
  }
}
