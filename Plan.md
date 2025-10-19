scg Implementation Plan
=======================

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
- Design the LLM provider abstraction so we can add an OpenAI-compatible HTTP client that talks to local servers (Ollama, llama.cpp bridges, LM Studio) without changing existing call sites; defer streaming support for now.
- Consider Linux/Windows support once we have an LLM provider abstraction.

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
   - 🔄 Evaluate context-compaction utilities so regenerated prompts reuse summary data without re-sending unchanged sections (batch planner now reuses summaries; refine regeneration flow).
3. ✅ Prepare graceful degradation
   - ✅ Surface actionable error message when the model is unavailable.
   - ⚪ Consider offline fallback prompt (e.g., reuse previous draft or instruct user) if model stays unavailable.

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
   - ✅ Persist diagnostics in JSON output or verbose mode for downstream tooling.
2. 🔄 Batching strategy
   - ✅ Build a `PromptBatchPlanner` that sorts files by estimated token contribution and greedily packs them into sub-prompts with ~15% safety headroom beneath the 4,096 token ceiling.
   - ✅ Surface per-batch diagnostics (token totals, file membership, overflow flags) alongside the existing prompt logging so we can trace which batch contains which files.
   - ✅ Generate partial commit drafts per batch using individual `LanguageModelSession` responses, capturing their diagnostics for later analysis.
   - ✅ Spin up a fresh `LanguageModelSession` to combine the partial drafts: feed repo metadata, batch summaries, and each partial commit message into a dedicated combiner prompt that produces the final subject/body.
   - 🔄 Implement fallback behavior when the combiner prompt nears the window (e.g., summarize partial subjects first or re-run with reduced context).
   - ✅ Revisit snippet truncation once batching is active: allow the planner to re-expand diff snippets (up to a generous hard cap that still fits a single file per batch) when spare token budget exists, and log which files get the “full” treatment versus compacted views.

Phase 5c: Alternate Model Providers 🚧
------------------------------------
1. 🔄 Add provider selection to `CommitGenOptions`
   - 🔄 Expand `UserConfiguration` + CLI flags to choose between `foundationModels` (default) and `openAICompatible`.
   - 🔄 Support environment overrides (`SCG_BASE_URL`, `SCG_MODEL`, `SCG_API_KEY`) for quick experimentation.
2. 🔄 Implement `OpenAICompatibleClient`
   - 🔄 Transform `PromptPackage` into chat-completions JSON and post to the configured base URL using `URLSession`.
   - 🔄 Parse usage metadata when available; fall back to local token estimates when the router omits counts.
   - 🔄 Handle network-level retries/timeouts mirroring the existing FoundationModels client.
3. 🔄 Validation & docs
   - 🔄 Add integration coverage with a mocked OpenAI endpoint plus a quickstart guide for running against Ollama or llama.cpp via their OpenAI-flavored routers.
   - 🔄 Document limitations (no streaming yet, assumes OpenAI-compatible schema) and expand manual verification checklist accordingly.

Phase 6: CLI Experience 🔄
-------------------------
1. ✅ Command flow
   - ✅ Default invocation runs inspection → summarization → model call → preview.
   - ✅ Default to staged changes only when generating drafts.
   - ✅ Auto-commit accepted drafts by default (disable with `--no-commit`).
2. 🔄 Interactive review
   - ✅ Print proposed subject/body; offer `y` (accept), `e` (edit in `$EDITOR`), `n` (abort).
   - ✅ Provide `--stage` to stage pending changes before drafting and run `git commit -F -` using the generated text when `--commit` is supplied.
   - ✅ Surface a summary of changes that will be committed alongside the draft.
   - ✅ Provide `r` (regenerate) and `c` (regenerate with context) options, reusing the current prompt package.
   - ✅ Add ANSI theming so logs and summaries highlight paths, additions, deletions, and metadata.
   - ✅ Add `--verbose` to opt into additional diagnostics and prompt-budget reporting.
   - 🔄 Catch `LanguageModelSession.GenerationError.exceededContextWindowSize`, warn the user, and retry with a trimmed prompt or fresh session snapshot.
3. ✅ Add `--print-json` for tooling integration (via `--format json`).

Phase 7: Configuration & Persistence 🔄
------------------------------------
1. ✅ Read and write user configuration (`~/Library/Application Support/scg/config.json`).
   - ✅ Manage defaults for auto-staging, verbosity, and generation mode via `scg config`.
   - 🔄 Extend configuration to cover prompt style, diff limits, and custom instructions.
2. 🔄 Provide `--config` override path and environment variable support.
   - 🔄 Document precedence between CLI flags, environment variables, and stored defaults once added.

Phase 8: Testing & Tooling
--------------------------
1. Write unit/integration tests
   - Mock `git` commands and model responses.
   - Use dependency injection for `ProcessRunner` and `LLMClient`.
   - Add targeted tests for `FoundationModelsClient` once a mockable session abstraction is in place.
2. Add sample fixtures for diff parsing and prompt generation.
