scg
===

scg is a Swift-based command line tool that inspects your current Git repository, summarizes the staged and unstaged changes, and generates a commit message proposal with Apple's on-device generative model. The goal is to keep human-in-the-loop Git commits fast, consistent, and privacy-preserving by relying on system-provided AI capabilities instead of cloud services.

https://github.com/user-attachments/assets/499e7b11-86af-490f-bb4e-c49c65c58ecf

Features
--------
- Detects dirty Git worktrees and extracts concise change context
- Crafts commit message drafts with Apple's onboard generative APIs
- Provides an interactive acceptance/edit flow before writing the commit
- Persists CLI defaults with an interactive `config` command
- Respects local-only privacy requirements (no network calls)

Project Status
--------------
The CLI currently supports end-to-end commit generation, including Git inspection, AI-assisted drafting, interactive editing, optional auto-staging/committing, and persistent configuration defaults. Advanced batching for huge diffs is available and continues to evolve based on real-world feedback.

Prerequisites
-------------
- macOS Tahoe (26) or later with the Apple Intelligence feature set enabled
- Xcode 26 (or newer) with the command line tools installed (`xcode-select --install`)
- Swift 6 toolchain (ships with Xcode 26)
- Git 2.40+ available on `PATH`
- Full Disk Access enabled for the Terminal (or your preferred shell) so the FoundationModels framework can initialize properly

Installation
------------

### Option 1: Homebrew (Recommended)

```sh
brew tap Iron-Ham/swift-commit-gen
brew install scg
```

Or install directly without tapping:

```sh
brew install Iron-Ham/swift-commit-gen/scg
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
install .build/release/scg "$HOME/.local/bin/"
```

Add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile if needed.

First-Run Notes
---------------
- The first invocation may prompt for Apple Intelligence access; approve the request in System Settings → Privacy & Security → Apple Intelligence.
- If `scg` reports that the model is unavailable, ensure Apple Intelligence is enabled and the device satisfies the on-device requirements.

Usage
-----
From the root of a Git repository with pending changes:

```sh
swift run scg generate
```

Or, after installation:

```sh
scg generate
```

### Command

You can invoke the tool either with the explicit `generate` subcommand or omit it because `generate` is the default subcommand.

Primary (shorter) form:

```sh
scg [OPTIONS]
```

Equivalent explicit form:

```sh
scg generate [OPTIONS]
```

### Generation Flow
1. Inspect repository (staged changes only)
2. Summarize diff and plan prompt batches if large
3. Request draft commit message from on-device model
4. Interactive review loop (accept / edit / regenerate)
5. Optional auto-commit

### Flags & Options

| Flag | Short | Description | Default | Notes |
|------|-------|-------------|---------|-------|
| `--format <text\|json>` |  | Output format for the draft | `text` | JSON skips the interactive review loop. |
| `--commit` / `--no-commit` |  | Apply the accepted draft with `git commit` | On | `--no-commit` leaves the draft uncommitted. |
| `--stage` |  | Stage all pending changes (including untracked) before drafting | Off | Equivalent to `git add --all` before generation. |
| `--no-stage` |  | Disable staging, even if configured as a default | - | Wins over stored auto-stage preferences. |
| `--verbose` | `-v` | Emit detailed prompt diagnostics and debug lines | Off | Shows `[DEBUG]` messages. Overrides `--quiet`. |
| `--no-verbose` |  | Force verbose output off, even if configured as default | - | Useful for scripts overriding stored settings. |
| `--quiet` | `-q` | Suppress routine info lines | Off | Hides `[INFO]` but keeps `[NOTICE]`, warnings, errors. Ignored if `--verbose` is present. |
| `--no-quiet` |  | Ensure quiet mode is disabled, even if configured | - | Helpful when scripts need full output. |
| `--single-file` |  | Analyze each file independently and then combine per-file drafts | Off | Sends a larger diff slice per file, useful when you need high-fidelity summaries. |
| `--function-context` |  | Include entire functions containing changes in the diff | On | Provides better semantic context for the AI model. |
| `--no-function-context` |  | Disable function context in diffs | - | May reduce diff size for very large changesets. |
| `--detect-renames` |  | Detect renamed and copied files in diffs | On | Shows moves as renames rather than delete + add. |
| `--no-detect-renames` |  | Disable rename/copy detection | - | Use raw add/delete representation. |
| `--context-lines <n>` |  | Number of context lines around changes | `3` | Higher values give more surrounding code context. |

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
scg
```

Auto-commit the already staged changes:

```sh
scg --commit
```

Stage everything first, then show verbose diagnostics:

```sh
scg --stage --verbose
```

Minimal essential output (quiet mode) but still commit:

```sh
scg --quiet --commit
```

Produce machine-readable JSON (no interactive loop):

```sh
scg --format json
```

Request high-fidelity per-file drafts before they are combined:

```sh
scg --single-file
```

Generate with more context lines and disabled function context (for very large diffs):

```sh
scg --context-lines 5 --no-function-context
```

Configuration Defaults
----------------------
Use the `config` subcommand to inspect or update stored defaults. Running it with no flags opens an interactive, colorized editor that walks through each preference:

```sh
scg config
```

Available options:

| Flag | Description |
|------|-------------|
| `--show` | Print the current configuration without making changes. |
| `--auto-stage-if-clean <true\|false>` | Persist whether `generate` should stage all files when nothing is staged. |
| `--clear-auto-stage` | Remove the stored auto-stage preference. |
| `--verbose <true\|false>` | Set the default verbose logging preference. |
| `--clear-verbose` | Remove the stored verbose preference. |
| `--quiet <true\|false>` | Set the default quiet logging preference. |
| `--clear-quiet` | Remove the stored quiet preference. |
| `--mode <automatic\|per-file>` | Set the default generation mode. |
| `--clear-mode` | Remove the stored generation mode preference. |
| `--function-context <true\|false>` | Set whether to include entire functions in diffs. |
| `--clear-function-context` | Remove the stored function-context preference. |
| `--detect-renames <true\|false>` | Set whether to detect renamed/copied files in diffs. |
| `--clear-detect-renames` | Remove the stored detect-renames preference. |
| `--context-lines <n>` | Set the default number of context lines around changes. |
| `--clear-context-lines` | Remove the stored context-lines preference. |

When no options are provided, the command detects whether the terminal is interactive and presents guided prompts with recommended defaults highlighted. Stored settings live in `~/Library/Application Support/scg/config.json`.

### Help

For a full list of commands:

```sh
scg help # or scg -h
```

For help with a specific command, such as `generate`:

```sh
scg help generate # or scg generate -h
```
