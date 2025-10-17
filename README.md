SwiftCommitGen
===============

SwiftCommitGen is a Swift-based command line tool that inspects your current Git repository, summarizes the staged and unstaged changes, and generates a commit message proposal with Apple's on-device generative model. The goal is to keep human-in-the-loop Git commits fast, consistent, and privacy-preserving by relying on system-provided AI capabilities instead of cloud services.

https://github.com/user-attachments/assets/499e7b11-86af-490f-bb4e-c49c65c58ecf

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

### Command

You can invoke the tool either with the explicit `generate` subcommand or omit it because `generate` is the default subcommand.

Primary (shorter) form:

```sh
swiftcommitgen [OPTIONS]
```

Equivalent explicit form:

```sh
swiftcommitgen generate [OPTIONS]
```

### Generation Flow
1. Inspect repository (staged + optionally unstaged changes)
2. Summarize diff and plan prompt batches if large
3. Request draft commit message from on-device model
4. Interactive review loop (accept / edit / regenerate)
5. Optional auto-stage and auto-commit

### Flags & Options

| Flag | Short | Description | Default | Notes |
|------|-------|-------------|---------|-------|
| `--staged-only` | `-s` | Only consider staged changes (ignore unstaged/untracked) | Off | Unstaged changes still can be staged later if `--stage` and `--commit` used. |
| `--format <text\|json>` |  | Output format for the draft | `text` | JSON skips interactive review (no edit/regen loop). |
| `--style <summary\|conventional\|detailed>` |  | Prompt style influencing draft format | `summary` | Conventional follows Conventional Commits subject style. |
| `--commit` / `--no-commit` |  | Apply the accepted draft with `git commit` | On | `--no-commit` leaves the draft uncommitted. |
| `--stage` / `--no-stage` |  | Stage unstaged/untracked files before committing | On (when `--commit`) | Ignored if `--no-commit`. |
| `--verbose` | `-v` | Emit detailed prompt diagnostics and debug lines | Off | Shows `[DEBUG]` messages. Overrides `--quiet`. |
| `--quiet` | `-q` | Suppress routine info lines | Off | Hides `[INFO]` but keeps `[NOTICE]`, warnings, errors. Ignored if `--verbose` is present. |

### Verbosity Levels

The logger uses distinct levels to balance clarity and noise:

- `[ERROR]`: Fatal issues preventing progress
- `[WARNING]`: Non-fatal problems or user action advisories
- `[NOTICE]`: Essential workflow milestones (always shown, even with `--quiet`)
- `[INFO]`: Routine progress details (hidden with `--quiet`)
- `[DEBUG]`: High-volume diagnostics (only with `--verbose`)

Precedence: `--verbose` > `--quiet`. Supplying both yields verbose output.

### Examples

Generate and interactively accept a draft (default):

```sh
swiftcommitgen
```

Limit to staged changes and auto-commit:

```sh
swiftcommitgen --staged-only --commit
```

Show detailed diagnostics while still auto-committing unstaged files:

```sh
swiftcommitgen --verbose --commit --stage
```

Minimal essential output (quiet mode) but still commit:

```sh
swiftcommitgen --quiet --commit
```

Produce machine-readable JSON (no interactive loop):

```sh
swiftcommitgen --format json
```

### Help

For a full list of commands:

```sh
swiftcommitgen help # or swiftcommitgen -h
```

For help with a specific command, such as `generate`:

```sh
swiftcommitgen help generate # or swiftcommitgen generate -h
```
