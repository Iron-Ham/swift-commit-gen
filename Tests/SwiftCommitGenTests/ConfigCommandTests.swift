import ArgumentParser
import Foundation
import Testing

@testable import SwiftCommitGen

struct ConfigCommandTests {
  @Test("interactive updates stored configuration")
  func interactiveUpdatesConfiguration() throws {
    let store = InMemoryConfigStore()
    let io = TestConfigCommandIO(inputs: ["1", "2"])
    try ConfigCommand.withDependencies(.init(makeStore: { store }, makeIO: { io })) {
      let command = try ConfigCommand.parse([])
      try command.run()
    }

    #expect(store.saveCallCount == 1)
    let saved = store.savedConfiguration
    #expect(saved?.autoStageIfNoStaged == true)
    #expect(saved?.defaultVerbose == true)
    #expect(saved?.defaultQuiet == nil)
  }

  @Test("interactive keeps existing values when inputs are empty")
  func interactiveKeepsConfigurationWhenBlank() throws {
    var initial = UserConfiguration()
    initial.autoStageIfNoStaged = true
    initial.defaultQuiet = true
    let store = InMemoryConfigStore(initial: initial)
    let io = TestConfigCommandIO(inputs: ["", ""])
    try ConfigCommand.withDependencies(.init(makeStore: { store }, makeIO: { io })) {
      let command = try ConfigCommand.parse([])
      try command.run()
    }

    #expect(store.saveCallCount == 0)
  }

  @Test("setting verbose clears quiet configuration")
  func directUpdatesClearConflictingQuiet() throws {
    var initial = UserConfiguration()
    initial.defaultQuiet = true
    let store = InMemoryConfigStore(initial: initial)
    let io = TestConfigCommandIO(inputs: [], isInteractive: false)
    try ConfigCommand.withDependencies(.init(makeStore: { store }, makeIO: { io })) {
      let command = try ConfigCommand.parse(["--verbose", "true"])
      try command.run()
    }

    #expect(store.saveCallCount == 1)
    let saved = store.savedConfiguration
    #expect(saved?.defaultVerbose == true)
    #expect(saved?.defaultQuiet == nil)
  }

  @Test("conflicting verbosity flags throw validation error")
  func conflictingVerbosityFlagsThrow() {
    let io = TestConfigCommandIO(inputs: [], isInteractive: false)
    let store = InMemoryConfigStore()
    #expect(throws: ValidationError.self) {
      try ConfigCommand.withDependencies(.init(makeStore: { store }, makeIO: { io })) {
        let command = try ConfigCommand.parse(["--verbose", "true", "--quiet", "true"])
        try command.run()
      }
    }
  }
}

final class TestConfigCommandIO: ConfigCommandIO {
  var isInteractive: Bool
  private(set) var outputs: [String] = []
  private(set) var prompts: [String] = []
  private var inputs: [String]

  init(inputs: [String], isInteractive: Bool = true) {
    self.inputs = inputs
    self.isInteractive = isInteractive
  }

  func printLine(_ text: String) {
    outputs.append(text)
  }

  func prompt(_ text: String) -> String? {
    prompts.append(text)
    if inputs.isEmpty {
      return ""
    }
    return inputs.removeFirst()
  }
}

final class InMemoryConfigStore: ConfigCommandStore {
  private var configuration: UserConfiguration
  private(set) var saveCallCount: Int = 0
  private(set) var savedConfiguration: UserConfiguration?
  private let location: URL

  init(
    initial: UserConfiguration = UserConfiguration(),
    location: URL = URL(fileURLWithPath: "/tmp/swiftcommitgen-config.json")
  ) {
    self.configuration = initial
    self.location = location
  }

  func load() throws -> UserConfiguration {
    configuration
  }

  func save(_ newConfiguration: UserConfiguration) throws {
    configuration = newConfiguration
    savedConfiguration = newConfiguration
    saveCallCount += 1
  }

  func configurationLocation() -> URL {
    location
  }
}
