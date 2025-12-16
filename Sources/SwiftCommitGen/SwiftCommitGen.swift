import ArgumentParser

@main
struct SwiftCommitGenCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "scg",
    abstract: "Generate AI-assisted Git commit messages using Apple's on-device models.",
    version: "0.6.0",
    subcommands: [GenerateCommand.self, ConfigCommand.self],
    defaultSubcommand: GenerateCommand.self
  )
}
