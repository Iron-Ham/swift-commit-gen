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
The CLI currently supports end-to-end commit generation, including Git inspection, AI-assisted drafting, interactive editing, and optional auto-staging/committing. Configuration files and advanced batching for huge diffs remain on the roadmap.

Prerequisites
-------------
- macOS 26 (Sequoia) or later with the Apple Intelligence feature set enabled
- Xcode 26 (or newer) with the command line tools installed (`xcode-select --install`)
- Swift 6 toolchain (ships with Xcode 26)
- Git 2.40+ available on `PATH`
- Full Disk Access enabled for the Terminal (or your preferred shell) so the FoundationModels framework can initialize properly

Installation
------------

### Option 1: Homebrew (Recommended)

```sh
brew tap Iron-Ham/swift-commit-gen
brew install swiftcommitgen
```

Or install directly without tapping:

```sh
brew install Iron-Ham/swift-commit-gen/swiftcommitgen
```

### Option 2: Install Script

1. Clone the repository:
	```sh
	git clone https://github.com/Iron-Ham/swift-commit-gen.git
	cd swift-commit-gen
	```
2. Run the bundled install script (installs into `~/.local/bin` by default):
	```sh
	Scripts/install.sh
	```
	Pass a custom destination as the first argument to install elsewhere, e.g. `Scripts/install.sh /usr/local/bin`.

### Option 3: Manual Build

If you prefer manual installation, build and copy the binary yourself:

```sh
git clone https://github.com/Iron-Ham/swift-commit-gen.git
cd swift-commit-gen
swift build -c release
install -d "$HOME/.local/bin"
install .build/release/swiftcommitgen "$HOME/.local/bin/"
```

Add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile if needed.

First-Run Notes
---------------
- The first invocation may prompt for Apple Intelligence access; approve the request in System Settings → Privacy & Security → Apple Intelligence.
- If `swiftcommitgen` reports that the model is unavailable, ensure Apple Intelligence is enabled and the device satisfies the on-device requirements.

Usage
-----
From the root of a Git repository with pending changes:

```sh
swift run swiftcommitgen generate
```

Or, after installation:

```sh
swiftcommitgen generate
```

Key options:
- `--staged`: limit analysis to staged changes only.
- `--format json`: emit the generated draft as JSON (skips interactive review).
- `--commit`: automatically run `git commit` after you accept the draft (combine with `--stage` to add unstaged files first).

Pass `--help` to list all available flags.
