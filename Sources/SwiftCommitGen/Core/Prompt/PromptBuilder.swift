protocol PromptBuilder {
  func makePrompt(from summary: ChangeSummary) -> PromptPackage
}

struct PromptPackage {
  var systemPrompt: String
  var userPrompt: String

  init(systemPrompt: String = "", userPrompt: String = "") {
    self.systemPrompt = systemPrompt
    self.userPrompt = userPrompt
  }
}

struct DefaultPromptBuilder: PromptBuilder {
  func makePrompt(from summary: ChangeSummary) -> PromptPackage {
    // Phase 4 will assemble meaningful prompts.
    return PromptPackage(
      systemPrompt: "You are an expert release engineer.",
      userPrompt: "Summaries are not yet available (\(summary.fileCount) file(s))."
    )
  }
}
