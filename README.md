scg
===

scg is a Swift-based command line tool that inspects your current Git repository, summarizes the staged and unstaged changes, and generates a commit message proposal using AI. The tool supports two backends:

- **FoundationModels** (macOS 26+): Uses Apple's on-device generative model for privacy-preserving, local-only generation
- **Ollama** (macOS 15+): Uses locally-hosted Ollama models for flexible, self-hosted AI generation

The goal is to keep human-in-the-loop Git commits fast, consistent, and privacy-preserving by relying on local AI capabilities instead of cloud services.

https://github.com/user-attachments/assets/499e7b11-86af-490f-bb4e-c49c65c58ecf

Features
--------
- Detects dirty Git worktrees and extracts concise change context
- Crafts commit message drafts with local AI models (FoundationModels or Ollama)
- Provides an interactive acceptance/edit flow before writing the commit
- Persists CLI defaults with an interactive `config` command
- Respects local-only privacy requirements (no network calls to cloud services)
- Flexible LLM backend support: choose between Apple Intelligence or Ollama

Project Status
--------------
The CLI currently supports end-to-end commit generation, including Git inspection, AI-assisted drafting, interactive editing, optional auto-staging/committing, and persistent configuration defaults. Advanced batching for huge diffs is available and continues to evolve based on real-world feedback.

Prerequisites
-------------

### For FoundationModels (macOS 26+)
- macOS Tahoe (26) or later with the Apple Intelligence feature set enabled
- Xcode 26 (or newer) with the command line tools installed (`xcode-select --install`)
- Swift 6 toolchain (ships with Xcode 26)
- Full Disk Access enabled for the Terminal (or your preferred shell) so the FoundationModels framework can initialize properly

### For Ollama (macOS 15+)
- macOS Sequoia (15) or later
- Xcode 16.1+ with Swift 6.1 toolchain
- [Ollama](https://ollama.ai) installed and running (`brew install ollama`)
- An Ollama model pulled (e.g., `ollama pull llama3.2`)

### Common Requirements
- Git 2.40+ available on `PATH`

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
| `--llm-provider <foundationModels\|ollama>` |  | Choose the LLM provider | `foundationModels` on macOS 26+, `ollama` on macOS 15 | Select which AI backend to use. |
| `--ollama-model <name>` |  | Ollama model to use | `llama3.2` | Only applicable when using Ollama provider. |
| `--ollama-base-url <url>` |  | Ollama API base URL | `http://localhost:11434` | Only applicable when using Ollama provider. |

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

Use Ollama instead of FoundationModels:

```sh
scg --llm-provider ollama
```

Use a specific Ollama model:

```sh
scg --llm-provider ollama --ollama-model codellama
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
| `--llm-provider <foundationModels\|ollama>` | Set the default LLM provider. |
| `--clear-llm-provider` | Remove the stored LLM provider preference. |
| `--ollama-model <name>` | Set the default Ollama model name. |
| `--clear-ollama-model` | Remove the stored Ollama model preference. |
| `--ollama-base-url <url>` | Set the default Ollama base URL. |
| `--clear-ollama-base-url` | Remove the stored Ollama base URL preference. |

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
