import ArgumentParser
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct ConfigCommand: ParsableCommand {
  /// User-facing generation modes exposed as CLI arguments.
  enum GenerationModeOption: String, ExpressibleByArgument, Codable {
    case automatic
    case perFile = "per-file"

    var mode: CommitGenOptions.GenerationMode {
      switch self {
      case .automatic:
        return .automatic
      case .perFile:
        return .perFile
      }
    }
  }

  /// Factored constructors for dependencies that make the command easy to test.
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
    abstract: "View or update stored defaults for scg."
  )

  @Flag(name: .long, help: "Display the current configuration without making changes.")
  var show: Bool = false

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

  @Option(name: .long, help: "Set the default generation mode (automatic|per-file).")
  var mode: GenerationModeOption?

  @Flag(name: .customLong("clear-mode"), help: "Remove the stored generation mode preference.")
  var clearMode: Bool = false

  @Option(name: .long, help: "Set the default LLM provider (foundationModels|ollama).")
  var llmProvider: String?

  @Flag(name: .customLong("clear-llm-provider"), help: "Remove the stored LLM provider preference.")
  var clearLLMProvider: Bool = false

  @Option(name: .long, help: "Set the default Ollama model name.")
  var ollamaModel: String?

  @Flag(name: .customLong("list-ollama-models"), help: "List available Ollama models.")
  var listOllamaModels: Bool = false

  @Flag(name: .customLong("clear-ollama-model"), help: "Remove the stored Ollama model preference.")
  var clearOllamaModel: Bool = false

  @Option(name: .long, help: "Set the default Ollama base URL.")
  var ollamaBaseURL: String?

  @Flag(
    name: .customLong("clear-ollama-base-url"),
    help: "Remove the stored Ollama base URL preference."
  )
  var clearOllamaBaseURL: Bool = false

  /// Runs the `scg config` subcommand either interactively or via direct flag updates.
  func run() throws {
    // Handle list-ollama-models flag first
    if listOllamaModels {
      listAvailableOllamaModels()
      return
    }

    try validateOptions()
    let dependencies = ConfigCommand.resolveDependencies()
    let store = dependencies.makeStore()
    var configuration = try store.load()
    let io = dependencies.makeIO()
    let theme = ConsoleTheme.resolve(stream: .stdout)

    let useInteractive = shouldRunInteractively && io.isInteractive
    var changed = false

    if useInteractive {
      let result = ConfigInteractiveEditor(io: io, theme: theme).edit(configuration: configuration)
      configuration = result.configuration
      changed = result.changed
    } else {
      changed = applyDirectUpdates(to: &configuration)
    }

    if changed {
      try store.save(configuration)
      print("Configuration updated at \(store.configurationLocation().path).")
    } else if shouldRunInteractively && !io.isInteractive {
      print(
        "Interactive configuration requires an interactive terminal. Pass flags to configure non-interactively."
      )
    }

    if useInteractive || show || changed {
      printConfiguration(configuration, location: store.configurationLocation(), theme: theme)
    } else if !changed {
      print("No configuration changes provided. Use --show to inspect current values.")
    }
  }

  /// Ensures mutually exclusive flags are not provided together.
  private func validateOptions() throws {
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
    if mode != nil && clearMode {
      throw ValidationError("Cannot use --mode together with --clear-mode.")
    }
    if llmProvider != nil && clearLLMProvider {
      throw ValidationError("Cannot use --llm-provider together with --clear-llm-provider.")
    }
    if ollamaModel != nil && clearOllamaModel {
      throw ValidationError("Cannot use --ollama-model together with --clear-ollama-model.")
    }
    if ollamaBaseURL != nil && clearOllamaBaseURL {
      throw ValidationError("Cannot use --ollama-base-url together with --clear-ollama-base-url.")
    }
  }

  /// Returns true when the command should launch the interactive editor.
  private var shouldRunInteractively: Bool {
    !show
      && autoStageIfClean == nil
      && !clearAutoStage
      && verbose == nil
      && !clearVerbose
      && quiet == nil
      && !clearQuiet
      && mode == nil
      && !clearMode
      && llmProvider == nil
      && !clearLLMProvider
      && ollamaModel == nil
      && !clearOllamaModel
      && !listOllamaModels
      && ollamaBaseURL == nil
      && !clearOllamaBaseURL
  }

  /// Applies configuration updates coming from explicit CLI flags.
  private func applyDirectUpdates(to configuration: inout UserConfiguration) -> Bool {
    var changed = false

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

    if clearMode {
      if configuration.defaultGenerationMode != nil {
        configuration.defaultGenerationMode = nil
        changed = true
      }
    }
    if let modeSelection = mode?.mode {
      switch modeSelection {
      case .automatic:
        if configuration.defaultGenerationMode != nil {
          configuration.defaultGenerationMode = nil
          changed = true
        }
      case .perFile:
        if configuration.defaultGenerationMode != .perFile {
          configuration.defaultGenerationMode = .perFile
          changed = true
        }
      }
    }

    if clearLLMProvider {
      if configuration.llmProvider != nil {
        configuration.llmProvider = nil
        changed = true
      }
    }
    if let providerString = llmProvider {
      let newProvider: CommitGenOptions.LLMProvider?
      switch providerString.lowercased() {
      case "foundationmodels":
        newProvider = .foundationModels
      case "ollama":
        // Get current ollama settings or use defaults
        let currentModel: String
        let currentBaseURL: String
        if case .ollama(let model, let baseURL) = configuration.llmProvider {
          currentModel = model
          currentBaseURL = baseURL
        } else {
          currentModel = "llama3.2"
          currentBaseURL = "http://localhost:11434"
        }
        // Override with CLI args if provided
        let finalModel = ollamaModel ?? currentModel
        let finalBaseURL = ollamaBaseURL ?? currentBaseURL
        newProvider = .ollama(model: finalModel, baseURL: finalBaseURL)
      default:
        print(
          "Warning: Invalid LLM provider '\(providerString)'. Use 'foundationModels' or 'ollama'."
        )
        newProvider = nil
      }

      if let newProvider, configuration.llmProvider != newProvider {
        configuration.llmProvider = newProvider
        changed = true
      }
    } else if ollamaModel != nil || ollamaBaseURL != nil {
      // Update Ollama settings only if already using Ollama
      if case .ollama(let currentModel, let currentBaseURL) = configuration.llmProvider {
        let finalModel = ollamaModel ?? currentModel
        let finalBaseURL = ollamaBaseURL ?? currentBaseURL
        let newProvider = CommitGenOptions.LLMProvider.ollama(
          model: finalModel,
          baseURL: finalBaseURL
        )
        if configuration.llmProvider != newProvider {
          configuration.llmProvider = newProvider
          changed = true
        }
      } else {
        print(
          "Warning: --ollama-model and --ollama-base-url only apply when using Ollama provider."
        )
      }
    }

    return changed
  }

  /// Prints the resolved configuration using the themed console output.
  private func printConfiguration(
    _ configuration: UserConfiguration,
    location: URL,
    theme: ConsoleTheme
  ) {
    let header = theme.applying(theme.emphasis, to: "Configuration file:")
    print("\(header) \(theme.applying(theme.path, to: location.path))")
    print("")

    let autoStagePref = configuration.autoStageIfNoStaged
    let autoStageCurrent = autoStagePref ?? false
    let autoStageNote: String?
    if autoStagePref == nil && !autoStageCurrent {
      autoStageNote = "(default)"
    } else {
      autoStageNote = nil
    }
    printPreference(
      title: "Auto-stage when clean",
      choices: [
        DisplayChoice(name: "enable", isCurrent: autoStageCurrent, isRecommended: true),
        DisplayChoice(name: "disable", isCurrent: !autoStageCurrent, note: autoStageNote),
      ],
      theme: theme
    )

    let isVerboseDefault = configuration.defaultVerbose == true
    let isQuietDefault = configuration.defaultQuiet == true
    let isStandardDefault = !isVerboseDefault && !isQuietDefault
    let standardNote =
      isStandardDefault && configuration.defaultVerbose == nil
        && configuration.defaultQuiet == nil ? "(default)" : nil
    printPreference(
      title: "Default verbosity",
      choices: [
        DisplayChoice(
          name: "standard",
          isCurrent: isStandardDefault,
          isRecommended: true,
          note: standardNote
        ),
        DisplayChoice(name: "verbose", isCurrent: isVerboseDefault),
        DisplayChoice(name: "quiet", isCurrent: isQuietDefault),
      ],
      theme: theme
    )

    let currentMode = configuration.defaultGenerationMode ?? .automatic
    let automaticNote =
      currentMode == .automatic && configuration.defaultGenerationMode == nil ? "(default)" : nil
    printPreference(
      title: "Generation mode",
      choices: [
        DisplayChoice(
          name: "automatic",
          isCurrent: currentMode == .automatic,
          isRecommended: true,
          note: automaticNote
        ),
        DisplayChoice(name: "per-file", isCurrent: currentMode == .perFile),
      ],
      theme: theme
    )

    // LLM Provider
    #if canImport(FoundationModels)
      let defaultLLMProvider: CommitGenOptions.LLMProvider = .foundationModels
      let foundationModelsRecommended = true
      let ollamaRecommended = false
    #else
      let defaultLLMProvider: CommitGenOptions.LLMProvider = .ollama(
        model: "llama3.2",
        baseURL: "http://localhost:11434"
      )
      let foundationModelsRecommended = false
      let ollamaRecommended = true
    #endif

    let currentLLMProvider = configuration.llmProvider ?? defaultLLMProvider
    let isUsingFoundationModels: Bool
    let isUsingOllama: Bool
    switch currentLLMProvider {
    case .foundationModels:
      isUsingFoundationModels = true
      isUsingOllama = false
    case .ollama:
      isUsingFoundationModels = false
      isUsingOllama = true
    }

    let llmProviderNote = configuration.llmProvider == nil ? "(default)" : nil

    printPreference(
      title: "LLM Provider",
      choices: [
        DisplayChoice(
          name: "foundationModels",
          isCurrent: isUsingFoundationModels,
          isRecommended: foundationModelsRecommended,
          note: isUsingFoundationModels ? llmProviderNote : nil
        ),
        DisplayChoice(
          name: "ollama",
          isCurrent: isUsingOllama,
          isRecommended: ollamaRecommended,
          note: isUsingOllama ? llmProviderNote : nil
        ),
      ],
      theme: theme
    )

    // Show Ollama model as a separate preference if Ollama is the provider
    if case .ollama(let model, let baseURL) = currentLLMProvider {
      // Get available models to show them as options
      let availableModels = fetchOllamaModels(baseURL: baseURL)

      if !availableModels.isEmpty {
        var modelChoices: [DisplayChoice] = []
        for availableModel in availableModels {
          // Normalize model names for comparison (handle :latest suffix)
          let normalizedAvailable =
            availableModel.hasSuffix(":latest")
            ? String(availableModel.dropLast(7))
            : availableModel
          let normalizedCurrent =
            model.hasSuffix(":latest")
            ? String(model.dropLast(7))
            : model

          let isCurrentModel = normalizedAvailable == normalizedCurrent || availableModel == model

          modelChoices.append(
            DisplayChoice(
              name: availableModel,
              isCurrent: isCurrentModel,
              isRecommended: false
            )
          )
        }

        printPreference(
          title: "Ollama Model",
          choices: modelChoices,
          theme: theme
        )
      } else {
        // If can't fetch models, just show the current one
        print(theme.applying(theme.emphasis, to: "Ollama Model:"))
        print("  > \(model) " + theme.applying(theme.infoLabel, to: "[current]"))
        print("")
      }

      print(theme.applying(theme.emphasis, to: "Ollama Base URL:"))
      print("  \(baseURL)")
      print("")
    }
  }

  /// Fetches available models from Ollama API.
  private func fetchOllamaModels(baseURL: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ollama", "list"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()

      guard process.terminationStatus == 0 else {
        return []
      }

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      guard let output = String(data: data, encoding: .utf8) else {
        return []
      }

      // Parse ollama list output
      // Format: NAME                    ID              SIZE      MODIFIED
      var models: [String] = []
      let lines = output.split(separator: "\n")
      for (index, line) in lines.enumerated() {
        // Skip header line
        if index == 0 { continue }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }

        // Get the first column (model name)
        let columns = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if let modelName = columns.first {
          models.append(String(modelName))
        }
      }

      return models
    } catch {
      return []
    }
  }

  /// Lists available Ollama models by executing `ollama list`.
  private func listAvailableOllamaModels() {
    let theme = ConsoleTheme.resolve(stream: .stdout)

    print(theme.applying(theme.emphasis, to: "Available Ollama models:"))
    print("")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ollama", "list"]

    let pipe = Pipe()
    process.standardOutput = pipe
    let errorPipe = Pipe()
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus != 0 {
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if let errorMessage = String(data: errorData, encoding: .utf8), !errorMessage.isEmpty {
          print(theme.applying(theme.muted, to: "Error: \(errorMessage)"))
        } else {
          print(
            theme.applying(
              theme.muted,
              to: "Error: Could not fetch Ollama models. Make sure Ollama is installed and running."
            )
          )
        }
        return
      }

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      if let output = String(data: data, encoding: .utf8) {
        print(output)
        print("")
        print(theme.applying(theme.muted, to: "To set a default model, use:"))
        print(theme.applying(theme.path, to: "  scg config --ollama-model <model-name>"))
      }
    } catch {
      print(theme.applying(theme.muted, to: "Error: \(error.localizedDescription)"))
    }
  }
}

private struct DisplayChoice {
  var name: String
  var isCurrent: Bool
  var isRecommended: Bool = false
  var note: String?
}

/// Renders a preference section with highlighted defaults in the CLI output.
private func printPreference(title: String, choices: [DisplayChoice], theme: ConsoleTheme) {
  print(theme.applying(theme.emphasis, to: "\(title):"))
  for choice in choices {
    let marker =
      choice.isCurrent
      ? theme.applying(theme.emphasis, to: ">")
      : theme.applying(theme.muted, to: " ")
    var description = "\(marker) \(choice.name)"
    if choice.isRecommended {
      description += " " + theme.applying(theme.muted, to: "(recommended)")
    }
    if let note = choice.note {
      description += " " + theme.applying(theme.muted, to: note)
    }
    if choice.isCurrent {
      description += " " + theme.applying(theme.infoLabel, to: "[current]")
    }
    print("  \(description)")
  }
  print("")
}

private enum ConfigCommandDependencyContext {
  @TaskLocal
  static var override: ConfigCommand.Dependencies?
}

extension ConfigCommand {
  /// Executes a closure with injected dependencies, reverting afterward.
  static func withDependencies<Result>(
    _ dependencies: Dependencies,
    run operation: () throws -> Result
  )
    rethrows -> Result
  {
    try ConfigCommandDependencyContext.$override.withValue(dependencies) {
      try operation()
    }
  }

  /// Resolves the active dependency factory set for the current context.
  static func resolveDependencies() -> Dependencies {
    ConfigCommandDependencyContext.override ?? Dependencies()
  }
}

extension ConfigCommand.Dependencies: @unchecked Sendable {}

/// Abstracts persistence for user configuration preferences.
protocol ConfigCommandStore {
  func load() throws -> UserConfiguration
  func save(_ configuration: UserConfiguration) throws
  func configurationLocation() -> URL
}

/// Type-erased adapter that allows swapping the underlying configuration store in tests.
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

/// Contract for emitting prompts and capturing responses during interactive editing.
protocol ConfigCommandIO: AnyObject {
  var isInteractive: Bool { get }
  func printLine(_ text: String)
  func prompt(_ text: String) -> String?
}

/// Default terminal-backed I/O implementation used by the config command.
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

/// Interactive editor that walks users through updating stored configuration values.
struct ConfigInteractiveEditor {
  private let io: any ConfigCommandIO
  private let theme: ConsoleTheme

  init(io: any ConfigCommandIO, theme: ConsoleTheme) {
    self.io = io
    self.theme = theme
  }

  func edit(
    configuration: UserConfiguration
  )
    -> (configuration: UserConfiguration, changed: Bool)
  {
    var updated = configuration
    let original = configuration

    let header = theme.applying(theme.emphasis, to: "Interactive configuration editor")
    let instructions = theme.applying(theme.muted, to: "(press Enter to keep current values)")
    io.printLine("\(header) \(instructions)")

    if let autoStageChoice = promptForAutoStage(current: configuration.autoStageIfNoStaged) {
      switch autoStageChoice {
      case .enabled:
        updated.autoStageIfNoStaged = true
      case .disabled:
        updated.autoStageIfNoStaged = false
      case .clear:
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

    if let modeChoice = promptForGenerationMode(current: configuration.defaultGenerationMode) {
      switch modeChoice {
      case .automatic:
        updated.defaultGenerationMode = nil
      case .perFile:
        updated.defaultGenerationMode = .perFile
      case .clear:
        updated.defaultGenerationMode = nil
      }
    }

    if let llmChoice = promptForLLMProvider(current: configuration.llmProvider) {
      switch llmChoice {
      case .foundationModels:
        updated.llmProvider = .foundationModels
      case .ollama(let model, let baseURL):
        updated.llmProvider = .ollama(model: model, baseURL: baseURL)
      case .clear:
        updated.llmProvider = nil
      }
    }

    // If Ollama is selected, prompt for model selection
    if case .ollama(let currentModel, let currentBaseURL) = updated.llmProvider {
      if let selectedModel = promptForOllamaModel(current: currentModel, baseURL: currentBaseURL) {
        updated.llmProvider = .ollama(model: selectedModel, baseURL: currentBaseURL)
      }
    }

    let changed =
      updated.autoStageIfNoStaged != original.autoStageIfNoStaged
      || updated.defaultVerbose != original.defaultVerbose
      || updated.defaultQuiet != original.defaultQuiet
      || updated.defaultGenerationMode != original.defaultGenerationMode
      || updated.llmProvider != original.llmProvider

    return (updated, changed)
  }

  /// Presents a numbered menu for toggling the auto-stage preference.
  private func promptForAutoStage(current: Bool?) -> AutoStageChoice? {
    let currentDescription: String
    switch current {
    case .some(true):
      currentDescription = "enabled"
    case .some(false), .none:
      currentDescription = "disabled"
    }

    let choices: [Choice<AutoStageChoice>] = [
      Choice(
        label: "1",
        tokens: ["1", "yes", "y", "enable"],
        description: "enable",
        value: .enabled,
        isRecommended: true
      ),
      Choice(
        label: "2",
        tokens: ["2", "no", "n", "disable"],
        description: "disable",
        value: .disabled
      ),
      Choice(
        label: "",
        tokens: ["clear", "reset"],
        description: "",
        value: .clear,
        isVisible: false
      ),
    ]

    return promptChoice(
      title: "Automatically stage files when none are staged",
      currentDescription: currentDescription,
      choices: choices,
      keepMessage: "Press Enter to keep current auto-stage preference.",
      isCurrent: { choiceValue in
        switch (choiceValue, current) {
        case (.enabled, .some(true)):
          return true
        case (.disabled, .some(false)):
          return true
        case (.disabled, .none):
          return true
        default:
          return false
        }
      },
      additionalInstructions: ["Type 'clear' to remove the stored preference."]
    )
  }

  /// Presents a numbered menu for selecting verbosity defaults.
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
      Choice(
        label: "1",
        tokens: ["1", "standard", "s"],
        description: "standard",
        value: .standard,
        isRecommended: true
      ),
      Choice(label: "2", tokens: ["2", "verbose", "v"], description: "verbose", value: .verbose),
      Choice(label: "3", tokens: ["3", "quiet", "q"], description: "quiet", value: .quiet),
    ]

    return promptChoice(
      title: "Default verbosity",
      currentDescription: description,
      choices: choices,
      keepMessage: "Press Enter to keep current verbosity.",
      isCurrent: { choiceValue in
        switch (choiceValue, currentChoice) {
        case (.standard, .standard), (.verbose, .verbose), (.quiet, .quiet):
          return true
        default:
          return false
        }
      }
    )
  }

  /// Presents a numbered menu for choosing the LLM provider.
  private func promptForLLMProvider(
    current: CommitGenOptions.LLMProvider?
  ) -> LLMProviderChoice? {
    let currentProvider =
      current
      ?? {
        #if canImport(FoundationModels)
          return CommitGenOptions.LLMProvider.foundationModels
        #else
          return CommitGenOptions.LLMProvider.ollama(
            model: "llama3.2",
            baseURL: "http://localhost:11434"
          )
        #endif
      }()

    let currentDescription: String
    switch currentProvider {
    case .foundationModels:
      currentDescription = "foundationModels"
    case .ollama:
      currentDescription = "ollama"
    }

    let choices: [Choice<LLMProviderChoice>] = [
      Choice(
        label: "1",
        tokens: ["1", "foundationmodels", "fm", "foundation"],
        description: "foundationModels (macOS 26+)",
        value: .foundationModels,
        isRecommended: {
          #if canImport(FoundationModels)
            return true
          #else
            return false
          #endif
        }()
      ),
      Choice(
        label: "2",
        tokens: ["2", "ollama", "o"],
        description: "ollama (local models)",
        value: .ollama(model: "", baseURL: ""),
        isRecommended: {
          #if canImport(FoundationModels)
            return false
          #else
            return true
          #endif
        }()
      ),
      Choice(
        label: "",
        tokens: ["clear", "reset"],
        description: "",
        value: .clear,
        isVisible: false
      ),
    ]

    let choice = promptChoice(
      title: "LLM Provider",
      currentDescription: currentDescription,
      choices: choices,
      keepMessage: "Press Enter to keep current provider",
      isCurrent: { choiceValue in
        switch (choiceValue, currentProvider) {
        case (.foundationModels, .foundationModels):
          return true
        case (.ollama, .ollama):
          return true
        default:
          return false
        }
      },
      additionalInstructions: ["Type 'clear' to remove the stored preference."]
    )

    // If user selected Ollama, keep current settings or use defaults
    guard case .ollama = choice else {
      return choice
    }

    // Get current model and baseURL
    let currentModel: String
    let currentBaseURL: String
    if case .ollama(let model, let baseURL) = currentProvider {
      currentModel = model
      currentBaseURL = baseURL
    } else {
      currentModel = "llama3.2"
      currentBaseURL = "http://localhost:11434"
    }

    return .ollama(model: currentModel, baseURL: currentBaseURL)
  }

  /// Presents a numbered menu for choosing an Ollama model.
  private func promptForOllamaModel(current: String, baseURL: String) -> String? {
    // Try to fetch available models from Ollama
    let availableModels = fetchOllamaModels(baseURL: baseURL)

    if availableModels.isEmpty {
      // Fallback to manual input if can't fetch models
      io.printLine("")
      io.printLine(
        theme.applying(
          theme.muted,
          to: "⚠ Could not fetch models from Ollama. Make sure Ollama is running."
        )
      )
      io.printLine(theme.applying(theme.emphasis, to: "Ollama Model"))
      io.printLine(theme.applying(theme.muted, to: "  Current: \(current)"))
      io.printLine(theme.applying(theme.muted, to: "  Press Enter to keep, or type model name:"))
      let modelResponse = io.prompt("  > ")
      if let response = modelResponse?.trimmingCharacters(in: .whitespacesAndNewlines),
        !response.isEmpty
      {
        return response
      }
      return nil
    }

    // Show available models
    io.printLine("")

    // Normalize current model name for comparison (handle :latest suffix)
    let normalizedCurrent =
      current.hasSuffix(":latest")
      ? String(current.dropLast(7))
      : current

    var modelChoices: [Choice<String>] = []
    for (index, model) in availableModels.enumerated() {
      let label = "\(index + 1)"

      // Normalize model name for comparison
      let normalizedModel =
        model.hasSuffix(":latest")
        ? String(model.dropLast(7))
        : model

      let isCurrentModel = normalizedModel == normalizedCurrent || model == current

      // Build comprehensive token list for matching user input
      var tokens = [label, model, model.lowercased()]
      // Add normalized version without :latest
      if model != normalizedModel {
        tokens.append(normalizedModel)
        tokens.append(normalizedModel.lowercased())
      }

      modelChoices.append(
        Choice(
          label: label,
          tokens: tokens,
          description: model,
          value: model,
          isRecommended: isCurrentModel
        )
      )
    }

    return promptChoice(
      title: "Ollama Model",
      currentDescription: current,
      choices: modelChoices,
      keepMessage: "Press Enter to keep current model",
      isCurrent: { selectedModel in
        let normalizedSelected =
          selectedModel.hasSuffix(":latest")
          ? String(selectedModel.dropLast(7))
          : selectedModel
        return normalizedSelected == normalizedCurrent || selectedModel == current
      },
      additionalInstructions: ["Type model name directly or select by number."]
    )
  }

  /// Fetches available models from Ollama API.
  private func fetchOllamaModels(baseURL: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ollama", "list"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()

      guard process.terminationStatus == 0 else {
        return []
      }

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      guard let output = String(data: data, encoding: .utf8) else {
        return []
      }

      // Parse ollama list output
      // Format: NAME                    ID              SIZE      MODIFIED
      var models: [String] = []
      let lines = output.split(separator: "\n")
      for (index, line) in lines.enumerated() {
        // Skip header line
        if index == 0 { continue }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }

        // Get the first column (model name)
        let columns = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if let modelName = columns.first {
          models.append(String(modelName))
        }
      }

      return models
    } catch {
      return []
    }
  }

  /// Presents a numbered menu for choosing the default generation mode.
  private func promptForGenerationMode(
    current: CommitGenOptions.GenerationMode?
  ) -> GenerationModeChoice? {
    let currentMode = current ?? .automatic
    let description: String = {
      switch currentMode {
      case .automatic:
        return "automatic"
      case .perFile:
        return "per-file"
      }
    }()

    let choices: [Choice<GenerationModeChoice>] = [
      Choice(
        label: "1",
        tokens: ["1", "automatic", "auto", "a"],
        description: "automatic",
        value: .automatic,
        isRecommended: true
      ),
      Choice(
        label: "2",
        tokens: ["2", "per-file", "perfile", "p"],
        description: "per-file",
        value: .perFile
      ),
      Choice(
        label: "",
        tokens: ["clear", "reset"],
        description: "",
        value: .clear,
        isVisible: false
      ),
    ]

    return promptChoice(
      title: "Generation mode",
      currentDescription: description,
      choices: choices,
      keepMessage: "Press Enter to keep current generation mode.",
      isCurrent: { choiceValue in
        switch (choiceValue, currentMode) {
        case (.automatic, .automatic), (.perFile, .perFile):
          return true
        default:
          return false
        }
      },
      additionalInstructions: [
        "Type 'clear' to remove the stored preference and fall back to automatic mode."
      ]
    )
  }

  /// Shared helper that renders choice menus and normalizes user input.
  private func promptChoice<Value>(
    title: String,
    currentDescription: String,
    choices: [Choice<Value>],
    keepMessage: String,
    isCurrent: (Value) -> Bool,
    additionalInstructions: [String] = []
  ) -> Value? {
    io.printLine("")
    let titleLine =
      theme.applying(theme.emphasis, to: "\(title) (")
      + theme.applying(theme.path, to: currentDescription)
      + theme.applying(theme.emphasis, to: "):")
    io.printLine(titleLine)

    for choice in choices where choice.isVisible {
      let choiceIsCurrent = isCurrent(choice.value)
      let marker =
        choiceIsCurrent
        ? theme.applying(theme.emphasis, to: ">")
        : theme.applying(theme.muted, to: " ")
      var line = "\(marker) \(choice.label)) \(choice.description)"
      if choice.isRecommended {
        line += " " + theme.applying(theme.muted, to: "(recommended)")
      }
      if choiceIsCurrent {
        line += " " + theme.applying(theme.infoLabel, to: "[current]")
      }
      io.printLine("  \(line)")
    }

    for instruction in additionalInstructions {
      io.printLine("  " + theme.applying(theme.muted, to: instruction))
    }

    while true {
      guard let response = io.prompt("Enter choice (\(keepMessage)): ") else { return nil }
      let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return nil }
      let normalized = trimmed.lowercased()
      if let match = choices.first(where: { $0.matches(normalized) }) {
        return match.value
      }
      io.printLine(theme.applying(theme.warningMessage, to: "Invalid selection. Please try again."))
    }
  }

  private struct Choice<Value> {
    let label: String
    let tokens: [String]
    let description: String
    let value: Value
    var isRecommended: Bool = false
    var isVisible: Bool = true

    func matches(_ input: String) -> Bool {
      tokens.contains(input.lowercased())
    }
  }

  private enum AutoStageChoice {
    case enabled
    case disabled
    case clear
  }

  private enum VerbosityChoice {
    case standard
    case verbose
    case quiet
  }

  private enum GenerationModeChoice {
    case automatic
    case perFile
    case clear
  }

  private enum LLMProviderChoice {
    case foundationModels
    case ollama(model: String, baseURL: String)
    case clear
  }
}
