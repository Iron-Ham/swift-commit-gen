import Foundation

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
		summarizer: DiffSummarizer? = nil,
		promptBuilder: PromptBuilder = DefaultPromptBuilder(),
		llmClient: LLMClient = FoundationModelsClient(),
		renderer: Renderer = ConsoleRenderer(),
		logger: CommitGenLogger = CommitGenLogger()
	) {
		self.options = options
		self.gitClient = gitClient
		self.summarizer = summarizer ?? DefaultDiffSummarizer(gitClient: gitClient)
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

		let summary = try await summarizer.summarize(
			status: status,
			includeStagedOnly: options.includeStagedOnly
		)
		logger.info(
			"Summary: \(summary.fileCount) file(s), +\(summary.totalAdditions) / -\(summary.totalDeletions)"
		)

		let branchName = (try? await gitClient.currentBranch()) ?? "HEAD"
		let repoName = repositoryName(from: repoRoot)
		let metadata = PromptMetadata(
			repositoryName: repoName,
			branchName: branchName,
			style: options.promptStyle,
			includeUnstagedChanges: !options.includeStagedOnly
		)

		let promptPackage = promptBuilder.makePrompt(summary: summary, metadata: metadata)

		if options.dryRun {
			renderDryRun(summary, prompt: promptPackage, metadata: metadata)
		}

		if !options.dryRun && options.outputFormat == .text {
			renderReviewSummary(summary)
		}

		logger.info("Requesting commit draft from the on-device language model…")
		var draft = try await llmClient.generateCommitDraft(from: promptPackage)
		renderer.render(draft, format: options.outputFormat)

		if options.dryRun {
			logger.info("Dry run complete. No commit was written.")
			return
		}

		guard options.outputFormat == .text else {
			logger.info("JSON output requested; skipping interactive review.")
			logger.warning(
				"Automated commit application is not implemented yet; integrate the JSON payload into your workflow manually."
			)
			return
		}

		if let reviewedDraft = try reviewDraft(initialDraft: draft) {
			draft = reviewedDraft
			try await handleAcceptedDraft(draft, summary: summary, status: status)
		} else {
			logger.warning("Commit generation flow aborted; no changes were committed.")
		}
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

	private func renderDryRun(
		_ summary: ChangeSummary,
		prompt: PromptPackage,
		metadata: PromptMetadata
	) {
		logger.info("Prompt style: \(metadata.style.rawValue)")
		logger.info("Detailed change summary:")
		for file in summary.files {
			logger.info("  - \(file.label): \(file.path) (+\(file.additions) / -\(file.deletions))")
			for line in file.snippet.prefix(6) {
				logger.info("     \(line)")
			}
		}

		logger.info("\nPrompt preview (system):")
		for line in prompt.systemPrompt.split(separator: "\n") {
			logger.info("  \(line)")
		}

		logger.info("\nPrompt preview (user):")
		for line in prompt.userPrompt.split(separator: "\n").prefix(30) {
			logger.info("  \(line)")
		}

		if prompt.userPrompt.split(separator: "\n").count > 30 {
			logger.info("  ... (user prompt truncated)")
		}
	}

	private func repositoryName(from url: URL) -> String {
		let candidate = url.lastPathComponent
		return candidate.isEmpty ? url.path : candidate
	}

	private func reviewDraft(initialDraft: CommitDraft) throws -> CommitDraft? {
		var currentDraft = initialDraft

		reviewLoop: while true {
			logger.info("Options: [y] accept, [e] edit in $EDITOR, [n] abort")
			guard let response = promptUser("Apply commit draft? [y/e/n]: ") else {
				continue
			}

			switch response {
			case "y", "yes":
				return currentDraft
			case "e", "edit":
				if let updated = try editDraft(currentDraft) {
					currentDraft = updated
					renderer.render(currentDraft, format: .text)
				}
			case "n", "no", "q", "quit":
				break reviewLoop
			default:
				logger.warning("Unrecognized option. Please respond with y, e, or n.")
			}
		}

		return nil
	}

	private func promptUser(_ prompt: String) -> String? {
		if let data = prompt.data(using: .utf8) {
			FileHandle.standardError.write(data)
		}
		guard let line = readLine() else {
			logger.warning("Unable to read response; aborting interaction.")
			return nil
		}
		return line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	private func editDraft(_ draft: CommitDraft) throws -> CommitDraft? {
		let environment = ProcessInfo.processInfo.environment
		guard let editor = environment["EDITOR"], !editor.isEmpty else {
			logger.warning("$EDITOR is not set; skipping edit request.")
			return nil
		}

		let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
			"swiftcommitgen-\(UUID().uuidString).txt"
		)
		defer { try? FileManager.default.removeItem(at: tempURL) }

		var contents = draft.subject
		if !draft.body.isEmpty {
			contents.append("\n\n")
			contents.append(draft.body)
		}
		contents.append("\n")
		try contents.write(to: tempURL, atomically: true, encoding: .utf8)

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		process.arguments = ["-c", "\(editor) \(tempURL.path)"]
		process.standardInput = FileHandle.standardInput
		process.standardOutput = FileHandle.standardOutput
		process.standardError = FileHandle.standardError
		process.environment = environment

		do {
			try process.run()
		} catch {
			logger.warning("Failed to launch $EDITOR (\(editor)): \(error.localizedDescription)")
			return nil
		}

		process.waitUntilExit()
		guard process.terminationStatus == 0 else {
			logger.warning(
				"Editor exited with status \(process.terminationStatus); keeping previous draft."
			)
			return nil
		}

		let updatedContents = try String(contentsOf: tempURL, encoding: .utf8)
		let updatedDraft = CommitDraft(responseText: updatedContents)

		guard !updatedDraft.subject.isEmpty else {
			logger.warning("Edited draft has an empty subject; keeping previous draft.")
			return nil
		}

		return updatedDraft
	}

	private func handleAcceptedDraft(
		_ draft: CommitDraft,
		summary: ChangeSummary,
		status: GitStatus
	) async throws {
		logger.info("Commit draft accepted.")

		guard options.autoCommit else {
			logger.warning(
				"Automated git commit remains optional. Run `git commit` manually using the accepted draft when ready."
			)
			return
		}

		if !options.includeStagedOnly {
			let hasPending = !status.unstaged.isEmpty || !status.untracked.isEmpty
			if hasPending {
				guard options.stageChanges else {
					logger.warning(
						"Unstaged changes detected; re-run with --stage to stage them automatically. Commit skipped."
					)
					return
				}

				try await stageChanges(for: status)
				logger.info("Staged unstaged/untracked changes before committing.")
			}
		}

		try await gitClient.commit(message: draft.commitMessage)
		logger.info("Git commit created successfully.")
	}

	private func renderReviewSummary(_ summary: ChangeSummary) {
		guard !summary.files.isEmpty else { return }
		logger.info("Reviewing \(summary.fileCount) file(s):")
		for file in summary.files {
			logger.info("  - \(file.path) (+\(file.additions) / -\(file.deletions)) [\(file.location)]")
		}
	}

	private func stageChanges(for status: GitStatus) async throws {
		let pending = status.unstaged + status.untracked
		guard !pending.isEmpty else { return }

		var paths: Set<String> = []
		for change in pending {
			paths.insert(change.path)
			if let old = change.oldPath {
				paths.insert(old)
			}
		}

		try await gitClient.stage(paths: Array(paths).sorted())
	}
}
