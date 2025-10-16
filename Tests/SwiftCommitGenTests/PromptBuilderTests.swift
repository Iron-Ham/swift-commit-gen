import Testing

@testable import SwiftCommitGen

struct PromptBuilderTests {
  @Test("Builds prompts with repository metadata and style guidance")
  func buildsPrompt() {
    let summary = ChangeSummary(files: [
      .init(
        path: "Sources/App/File.swift",
        oldPath: nil,
        kind: .modified,
        location: .staged,
        additions: 3,
        deletions: 1,
        snippet: ["+let value = 2", "-let value = 1"]
      ),
      .init(
        path: "Docs/Guide.md",
        oldPath: "Docs/OldGuide.md",
        kind: .renamed,
        location: .unstaged,
        additions: 1,
        deletions: 1,
        snippet: ["@@ renamed docs"]
      ),
    ])

    let metadata = PromptMetadata(
      repositoryName: "SwiftCommitGen",
      branchName: "feature/awesome",
      style: .conventional,
      includeUnstagedChanges: true
    )

    let builder = DefaultPromptBuilder(maxFiles: 5, maxSnippetLines: 3)
    let package = builder.makePrompt(summary: summary, metadata: metadata)

  #expect(package.systemPrompt.contains("You're an AI assistant"))
  #expect(package.systemPrompt.contains("\"title\""))
  #expect(package.systemPrompt.contains("Conventional Commits"))
    #expect(package.systemPrompt.contains("type: subject"))
    #expect(package.userPrompt.contains("SwiftCommitGen"))
    #expect(package.userPrompt.contains("feature/awesome"))
    #expect(package.userPrompt.contains("Sources/App/File.swift"))
    #expect(package.userPrompt.contains("Docs/OldGuide.md -> Docs/Guide.md"))
  }
}
