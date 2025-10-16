protocol DiffSummarizer {
  func summarize(includeStagedOnly: Bool) async throws -> DiffSummary
}

struct DiffSummary {
  var files: [String] = []
}

struct DefaultDiffSummarizer: DiffSummarizer {
  func summarize(includeStagedOnly: Bool) async throws -> DiffSummary {
    // Phase 3 will produce real diff summaries.
    return DiffSummary()
  }
}
