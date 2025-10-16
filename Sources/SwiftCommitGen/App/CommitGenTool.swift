struct CommitGenTool {
  private let options: CommitGenOptions
  private let gitClient: GitClient
  private let summarizer: DiffSummarizer
  private let promptBuilder: PromptBuilder
  private let llmClient: LLMClient
  private let renderer: Renderer
  private let logger: CommitGenLogger

  init(
    options: CommitGenOptions,
    gitClient: GitClient = SystemGitClient(),
    summarizer: DiffSummarizer = DefaultDiffSummarizer(),
    promptBuilder: PromptBuilder = DefaultPromptBuilder(),
    llmClient: LLMClient = FoundationModelsClient(),
    renderer: Renderer = ConsoleRenderer(),
    logger: CommitGenLogger = CommitGenLogger()
  ) {
    self.options = options
    self.gitClient = gitClient
    self.summarizer = summarizer
    self.promptBuilder = promptBuilder
    self.llmClient = llmClient
    self.renderer = renderer
    self.logger = logger
  }

  func run() async throws {
    let repoRoot = try await gitClient.repositoryRoot()
    logger.info("Repository root: \(repoRoot.path)")

    let status = try await gitClient.status()
    let scope: GitChangeScope = options.includeStagedOnly ? .staged : .all
    let changes = status.changes(for: scope)

    guard !changes.isEmpty else {
      throw CommitGenError.cleanWorkingTree
    }

    logger.info("Detected \(changes.count) pending change(s) in \(describe(scope: scope)) scope.")

    if options.dryRun {
      logger.info("Listing files:")
      for change in changes {
        logger.info("  \(change.summary)")
      }
      logger.warning("Dry run complete. Commit message generation arrives in a later phase.")
      return
    }

    logger.warning("Git inspection succeeded. Commit generation is not yet implemented.")
  }

  private func describe(scope: GitChangeScope) -> String {
    switch scope {
    case .staged:
      return "staged"
    case .unstaged:
      return "unstaged"
    case .all:
      return "staged + unstaged"
    }
  }
}
