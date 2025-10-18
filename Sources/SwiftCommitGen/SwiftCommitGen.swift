import ArgumentParser

@main
struct SwiftCommitGenCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "swiftcommitgen",
    abstract: "Generate AI-assisted Git commit messages using Apple's on-device models.",
    version: "0.1.1",
    subcommands: [GenerateCommand.self],
    defaultSubcommand: GenerateCommand.self
  )
}
