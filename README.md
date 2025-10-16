SwiftCommitGen
===============

SwiftCommitGen is a Swift-based command line tool that inspects your current Git repository, summarizes the staged and unstaged changes, and generates a commit message proposal with Apple's on-device generative model. The goal is to keep human-in-the-loop Git commits fast, consistent, and privacy-preserving by relying on system-provided AI capabilities instead of cloud services.

Features
--------
- Detects dirty Git worktrees and extracts concise change context
- Crafts commit message drafts with Apple's onboard generative APIs
- Provides interactive acceptance or edit flow before writing the commit
- Respects local-only privacy requirements (no network calls)

Project Status
--------------
This repository currently contains the project scaffold while the CLI implementation is underway. The README captures the target behavior and development plan so contributors can align on goals early.

Prerequisites
-------------
- macOS 26 (Sequoia) or later with the Apple Intelligence feature set enabled
- Xcode 26 (or newer) with the command line tools installed (`xcode-select --install`)
- Swift 6 toolchain (ships with Xcode 26)
- Git 2.40+ available on `PATH`

Planned Workflow
----------------
The CLI will perform the following steps when invoked:
1. Verify the current working directory is part of a Git repository.
2. Abort if the worktree is clean, otherwise gather staged and unstaged diffs.
3. Generate a structured summary of the changes (file list, diff highlights).
4. Prompt Apple's onboard LLM via the Swift Intelligence framework with the summary and project metadata.
5. Present the AI-generated commit title and body for confirmation or manual edits.
6. Optionally write the commit (`git commit`) when approved.

Roadmap
-------
- [ ] Implement Git status inspection and change summarization utilities
- [ ] Integrate with Apple's Intelligence framework for local inference
- [ ] Provide interactive terminal UI for accepting/editing generated messages
- [ ] Add configuration options (prompt templates, verbosity, output format)
- [ ] Document testing strategy and add automated tests
