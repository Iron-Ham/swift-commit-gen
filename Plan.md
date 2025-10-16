SwiftCommitGen Implementation Plan
=================================

Guiding Principles
------------------
- Target macOS 26+ with the FoundationModels framework to keep inference on-device.
- Assume the tool is always executed from a Git working tree root.
- Keep user in control of the final commit message; never auto-commit without confirmation.
- Structure code for testability (separate git plumbing, diff summarization, model prompting, CLI UX).

Phase 1: Project Foundations
----------------------------
1. Update `Package.swift`
   - Add FoundationModels, Swift Argument Parser, and Swift Collections (for ordered data structures) as dependencies if needed.
2. Restructure sources
   - Create modules for `CommitGenTool` (CLI entry point), `GitClient`, `DiffSummarizer`, `PromptBuilder`, `LLMClient`, and `Renderer`.
   - Provide minimal `main.swift` using ArgumentParser with a `generate` command (default).
3. Establish logging + error types
   - Define `CommitGenError` (enum) with cases for I/O, git, model, validation.
   - Add lightweight logger (stderr output) for debug tracing.

Phase 2: Git Inspection Layer
-----------------------------
1. Implement `GitClient`
   - Methods: `repositoryRoot()`, `status()`, `diffStaged()`, `diffUnstaged()`, `listChangedFiles()`.
   - Execute `git` via `Process`, pipe stdout/stderr, map to Swift structs.
2. Add validation helpers
   - Ensure working tree is dirty; otherwise return early (clean state message).
   - Provide option to limit staged vs unstaged scope.
3. Unit tests (where feasible)
   - Use temporary directories with initialized git repos to validate parsing logic.

Phase 3: Change Summarization
-----------------------------
1. Design `ChangeSummary` model
   - File metadata (path, status), diff chunk previews, language hints.
2. Implement `DiffSummarizer`
   - Parse unified diff output; trim context to configurable max lines.
   - Detect rename/add/delete markers.
3. Add heuristics
   - Collapse large diffs with placeholders like `<<skipped N lines>>`.
   - Identify tests vs source changes to inform prompting.

Phase 4: Prompt Construction
----------------------------
1. Build `PromptBuilder`
   - Compose system + user messages for Apple model (JSON or plain text; TBD after API exploration).
   - Include repo name, branch, optional Conventional Commit preference.
2. Support different styles
   - Provide flags for `--style conventional|summary|detailed`.
   - Allow user-provided prompt snippets via config file.

Phase 5: FoundationModels Integration
-------------------------------------
1. Explore API
   - Investigate `TextGeneration` APIs (likely `TextGenerationSession` or `FMText` equivalents) for on-device inference.
   - Prototype prompt invocation in isolation with static text to confirm output handling.
2. Implement `LLMClient`
   - Initialize model session with temperature, max tokens, stop sequences tuned for commit messages.
   - Provide async `generateCommitMessage(summary: PromptContext) -> CommitDraft`.
   - Handle retries, timeouts, and fallback messaging.
3. Prepare graceful degradation
   - If the model is unavailable or disabled, surface actionable error message.

Phase 6: CLI Experience
-----------------------
1. Command flow
   - Default invocation runs inspection → summarization → model call → preview.
   - Provide `--staged` to limit to staged changes; `--dry-run` to skip `git commit`.
2. Interactive review
   - Print proposed subject/body; offer `y` (accept), `e` (edit in `$EDITOR`), `n` (abort).
   - On accept, stage (if opted) and run `git commit -F -` using generated text.
3. Add `--print-json` for tooling integration.

Phase 7: Configuration & Persistence
------------------------------------
1. Read config file `.swiftcommitgen.toml/json`
   - Options for default style, max diff lines, custom instructions, auto-stage toggle.
2. Provide `--config` override path and environment variable support.

Phase 8: Testing & Tooling
--------------------------
1. Write unit/integration tests
   - Mock `git` commands and model responses.
   - Use dependency injection for `ProcessRunner` and `LLMClient`.
2. Add sample fixtures for diff parsing and prompt generation.
3. Create `swift test` workflow and document manual verification steps.

Phase 9: Documentation & Release Prep
-------------------------------------
1. Expand README with installation, usage, and troubleshooting.
2. Add CHANGELOG, LICENSE, and contribution guidelines.
3. Prepare Homebrew tap formula or binary distribution instructions (future).

Milestones
----------
- M1: Git inspection + diff summarization works with `--dry-run` (no AI).
- M2: Model integration produces commit proposals (manual acceptance).
- M3: Configurable CLI with tests and documentation ready for v0.1.0.
