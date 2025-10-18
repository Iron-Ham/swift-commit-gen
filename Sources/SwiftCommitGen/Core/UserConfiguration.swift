import Foundation

struct UserConfiguration: Codable {
  var preferredStyle: CommitGenOptions.PromptStyle?
  var autoStageIfNoStaged: Bool?
  var defaultVerbose: Bool?
  var defaultQuiet: Bool?
}

struct UserConfigurationStore {
  private let fileManager: FileManager
  private let configurationURL: URL

  init(fileManager: FileManager = .default, url: URL? = nil) {
    self.fileManager = fileManager
    self.configurationURL =
      url ?? UserConfigurationStore.defaultConfigurationURL(fileManager: fileManager)
  }

  func load() throws -> UserConfiguration {
    if !fileManager.fileExists(atPath: configurationURL.path) {
      return UserConfiguration()
    }

    let data = try Data(contentsOf: configurationURL)
    let decoder = JSONDecoder()
    return try decoder.decode(UserConfiguration.self, from: data)
  }

  func save(_ configuration: UserConfiguration) throws {
    let directory = configurationURL.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: directory.path) {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(configuration)
    try data.write(to: configurationURL, options: .atomic)
  }

  func configurationLocation() -> URL {
    configurationURL
  }

  private static func defaultConfigurationURL(fileManager: FileManager) -> URL {
    let baseDirectory: URL
    let processEnv = ProcessInfo.processInfo.environment
    if let xdgHome = processEnv["XDG_CONFIG_HOME"], !xdgHome.isEmpty {
      baseDirectory = URL(fileURLWithPath: xdgHome, isDirectory: true)
    } else {
      let home = fileManager.homeDirectoryForCurrentUser
      #if os(macOS)
      baseDirectory = home.appendingPathComponent("Library/Application Support", isDirectory: true)
      #else
      baseDirectory = home.appendingPathComponent(".config", isDirectory: true)
      #endif
    }

    return baseDirectory
      .appendingPathComponent("swiftcommitgen", isDirectory: true)
      .appendingPathComponent("config.json", isDirectory: false)
  }
}
