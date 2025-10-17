SwiftCommitGen Implementation Plan
=================================

Guiding Principles
------------------
- Target macOS 26+ with the FoundationModels framework to keep inference on-device.
- Assume the tool is always executed from a Git working tree root.
- Keep user in control of the final commit message; never auto-commit without confirmation.
- Structure code for testability (separate git plumbing, diff summarization, model prompting, CLI UX).

Current Focus (October 2025)
----------------------------
- Validate prompt augmentation so each regeneration carries forward only the necessary context.
- Track how much summary data we resend to the model and prune redundant payloads to stay within small context windows.
- Surface prompt-budget diagnostics so we can tune heuristics with real usage data (include token estimates + warnings).
- Capture insights from TN3193: treat 4,096 tokens as the working ceiling, plan for multi-session strategies, and log when heuristics get close so we can react before `exceededContextWindowSize` fires.
- Document how to validate token budgets using the Foundation Models Instruments profile run; bake those steps into our manual verification checklist.
- Prepare heuristics to merge user-supplied annotations with existing prompts without duplicating repo metadata.

Phase 1: Project Foundations ✅
------------------------------
1. ✅ Update `Package.swift`
   - ✅ Add FoundationModels, Swift Argument Parser, and Swift Collections (for ordered data structures) as dependencies if needed.
2. ✅ Restructure sources
   - ✅ Create modules for `CommitGenTool` (CLI entry point), `GitClient`, `DiffSummarizer`, `PromptBuilder`, `LLMClient`, and `Renderer`.
   - ✅ Provide minimal `main.swift` using ArgumentParser with a `generate` command (default).
3. ✅ Establish logging + error types
   - ✅ Define `CommitGenError` (enum) with cases for I/O, git, model, validation.
   - ✅ Add lightweight logger (stderr output) for debug tracing.

Phase 2: Git Inspection Layer ✅
-------------------------------
1. ✅ Implement `GitClient`
   - ✅ Methods: `repositoryRoot()`, `status()`, `diffStaged()`, `diffUnstaged()`, `listChangedFiles()`, `currentBranch()`.
   - ✅ Execute `git` via `Process`, pipe stdout/stderr, map to Swift structs.
2. ✅ Add validation helpers
   - ✅ Ensure working tree is dirty; otherwise return early (clean state message).
   - ✅ Provide option to limit staged vs unstaged scope.
3. ✅ Unit tests (where feasible)
   - ✅ Use temporary directories with initialized git repos to validate parsing logic.

Phase 3: Change Summarization ✅
-------------------------------
1. ✅ Design `ChangeSummary` model
   - ✅ File metadata (path, status), diff chunk previews, language hints.
2. ✅ Implement `DiffSummarizer`
   - ✅ Parse unified diff output; trim context to configurable max lines.
   - ✅ Detect rename/add/delete markers.
3. ✅ Add heuristics
   - ✅ Collapse large diffs with placeholders like `<<skipped N lines>>`.
   - ✅ Identify tests vs source changes to inform prompting.

Phase 4: Prompt Construction ✅
------------------------------
1. ✅ Build `PromptBuilder`
   - ✅ Compose system + user messages for Apple model (plain text for now).
   - ✅ Include repo name, branch, optional Conventional Commit preference.
2. ✅ Support different styles
   - ✅ Provide flags for `--style conventional|summary|detailed`.
   - ⚪ Allow user-provided prompt snippets via config file (deferred to Phase 7).

Phase 5: FoundationModels Integration 🔄
---------------------------------------
1. ✅ Explore API
   - ✅ Investigate `LanguageModelSession` API for on-device inference.
   - ✅ Prototype prompt invocation pattern.
2. 🔄 Implement `LLMClient`
   - ✅ Initialize model session with temperature / response limits tuned for commit messages.
   - ✅ Provide async `generateCommitDraft(summary:)` returning `CommitDraft`.
   - 🔄 Handle retries, timeouts, and richer fallback messaging when generation fails mid-flight.
   - 🔄 Evaluate context-compaction utilities so regenerated prompts reuse summary data without re-sending unchanged sections.
3. ✅ Prepare graceful degradation
   - ✅ Surface actionable error message when the model is unavailable.
   - ⚪ Consider offline fallback prompt (e.g., reuse previous draft or instruct user) if model stays unavailable.

Phase 6: CLI Experience 🔄
-------------------------
1. ✅ Command flow
   - ✅ Default invocation runs inspection → summarization → model call → preview.
   - ✅ Provide `--staged` to limit to staged changes.
   - ✅ Auto-commit accepted drafts by default (disable with `--no-commit`).
2. 🔄 Interactive review
   - ✅ Print proposed subject/body; offer `y` (accept), `e` (edit in `$EDITOR`), `n` (abort).
   - ✅ On accept, optionally stage files (`--stage`) and run `git commit -F -` using the generated text (`--commit`).
   - ✅ Surface a summary of changes that will be committed alongside the draft.
   - ✅ Provide `r` (regenerate) and `c` (regenerate with context) options, reusing the current prompt package.
   - ✅ Add ANSI theming so logs and summaries highlight paths, additions, deletions, and metadata.
   - ✅ Add `--verbose` to opt into additional diagnostics and prompt-budget reporting.
   - 🔄 Catch `LanguageModelSession.GenerationError.exceededContextWindowSize`, warn the user, and retry with a trimmed prompt or fresh session snapshot.
3. ✅ Add `--print-json` for tooling integration (via `--format json`).

Phase 5b: Prompt Budget & Batching 🚧
-----------------------------------
1. 🔄 Prompt heuristics
   - ✅ Capture large/binary diff metadata to summarize oversized changes without raw snippets.
   - ✅ Add adaptive compaction that trims snippets and file counts when prompts exceed line budgets.
   - ✅ Detect files flagged as generated via `.gitattributes` (`linguist-generated`) and avoid sending their diffs.
   - ✅ Log prompt diagnostics (line usage, truncation, generated omissions, representative hints) for every generation.
   - ✅ Tune per-file thresholds and truncation messaging for high-volume repositories.
      - ✅ Estimate token usage and warn when nearing the model's context window.
      - 🔄 Run periodic Foundation Models Instruments sessions to compare real prompt/completion usage against our estimates and feed adjustments back into heuristics.
   - 🔄 Analyze augmented user prompts to ensure default metadata isn’t duplicated during context regeneration.
   - 🔄 Persist diagnostics in JSON output or verbose mode for downstream tooling.
2. ⚪ Batching strategy
   - 🔄 Build a `PromptBatchPlanner` that sorts files by estimated token contribution and greedily packs them into sub-prompts with ~15% safety headroom beneath the 4,096 token ceiling.
   - ⚪ Surface per-batch diagnostics (token totals, file membership, overflow flags) alongside the existing prompt logging so we can trace which batch contains which files.
   - ⚪ Generate partial commit drafts per batch using individual `LanguageModelSession` responses, capturing their diagnostics for later analysis.
   - ⚪ Spin up a fresh `LanguageModelSession` to combine the partial drafts: feed repo metadata, batch summaries, and each partial commit message into a dedicated combiner prompt that produces the final subject/body.
   - ⚪ Implement fallback behavior when the combiner prompt nears the window (e.g., summarize partial subjects first or re-run with reduced context).

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
   - Add targeted tests for `FoundationModelsClient` once a mockable session abstraction is in place.
2. Add sample fixtures for diff parsing and prompt generation.
3. Create `swift test` workflow and document manual verification steps.

Phase 9: Documentation & Release Prep
-------------------------------------
1. Expand README with installation, usage, and troubleshooting.
2. Add CHANGELOG, LICENSE, and contribution guidelines.
3. Prepare Homebrew tap formula or binary distribution instructions (future).

Milestones
----------
- M1: Git inspection + diff summarization works without invoking the model (pure analysis mode).
- M2: Model integration produces commit proposals (manual acceptance).
- M3: Configurable CLI with tests and documentation ready for v0.1.0.
