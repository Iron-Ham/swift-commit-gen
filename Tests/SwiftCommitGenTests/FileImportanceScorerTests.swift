import Foundation
import Testing

@testable import SwiftCommitGen

struct FileImportanceScorerTests {
  @Test("Type definitions get high scores")
  func typeDefinitionsGetHighScores() {
    let typeDefFile = makeFileSummary(
      path: "Sources/App/Model.swift",
      changeHints: ["type definition"],
      kind: .modified
    )

    let regularFile = makeFileSummary(
      path: "Sources/App/Helpers.swift",
      changeHints: [],
      kind: .modified
    )

    let scorer = FileImportanceScorer()
    let scored = scorer.scoreFiles([typeDefFile, regularFile])

    #expect(scored[0].file.path == "Sources/App/Model.swift")
    #expect(scored[0].score > scored[1].score)
  }

  @Test("New files get bonus score")
  func newFilesGetBonusScore() {
    let newFile = makeFileSummary(
      path: "Sources/App/NewFeature.swift",
      changeHints: [],
      kind: .added
    )

    let modifiedFile = makeFileSummary(
      path: "Sources/App/Existing.swift",
      changeHints: [],
      kind: .modified
    )

    let scorer = FileImportanceScorer()
    let scores = scorer.scoresByPath([newFile, modifiedFile])

    #expect(scores["Sources/App/NewFeature.swift"]! > scores["Sources/App/Existing.swift"]!)
  }

  @Test("Test files get lower scores")
  func testFilesGetLowerScores() {
    let sourceFile = makeFileSummary(
      path: "Sources/App/Feature.swift",
      changeHints: [],
      kind: .modified
    )

    let testFile = makeFileSummary(
      path: "Tests/AppTests/FeatureTests.swift",
      changeHints: ["test changes"],
      kind: .modified
    )

    let scorer = FileImportanceScorer()
    let scored = scorer.scoreFiles([sourceFile, testFile])

    #expect(scored[0].file.path == "Sources/App/Feature.swift")
    #expect(scored[0].score > scored[1].score)
  }

  @Test("Generated files get very low scores")
  func generatedFilesGetVeryLowScores() {
    let generatedFile = makeFileSummary(
      path: "Generated/API.swift",
      changeHints: [],
      kind: .modified,
      isGenerated: true
    )

    let regularFile = makeFileSummary(
      path: "Sources/App/Feature.swift",
      changeHints: [],
      kind: .modified
    )

    let scorer = FileImportanceScorer()
    let scored = scorer.scoreFiles([generatedFile, regularFile])

    #expect(scored[0].file.path == "Sources/App/Feature.swift")
    #expect(scored[0].score > scored[1].score)
    #expect(scored[1].score < 0)  // Generated files should have negative scores
  }

  @Test("Lock files get very low scores")
  func lockFilesGetVeryLowScores() {
    let lockFile = makeFileSummary(
      path: "package-lock.json",
      changeHints: [],
      kind: .modified
    )

    let regularFile = makeFileSummary(
      path: "Sources/App/Feature.swift",
      changeHints: [],
      kind: .modified
    )

    let scorer = FileImportanceScorer()
    let scores = scorer.scoresByPath([lockFile, regularFile])

    #expect(scores["Sources/App/Feature.swift"]! > scores["package-lock.json"]!)
  }

  @Test("High change volume increases score")
  func highChangeVolumeIncreasesScore() {
    let highChangeFile = makeFileSummary(
      path: "Sources/App/BigChange.swift",
      changeHints: [],
      kind: .modified,
      additions: 150,
      deletions: 50
    )

    let smallChangeFile = makeFileSummary(
      path: "Sources/App/SmallChange.swift",
      changeHints: [],
      kind: .modified,
      additions: 5,
      deletions: 2
    )

    let scorer = FileImportanceScorer()
    let scores = scorer.scoresByPath([highChangeFile, smallChangeFile])

    #expect(scores["Sources/App/BigChange.swift"]! > scores["Sources/App/SmallChange.swift"]!)
  }

  @Test("Protocol conformance hints increase score")
  func protocolConformanceIncreasesScore() {
    let protocolFile = makeFileSummary(
      path: "Sources/App/Conformance.swift",
      changeHints: ["protocol conformance"],
      kind: .modified
    )

    let regularFile = makeFileSummary(
      path: "Sources/App/Regular.swift",
      changeHints: [],
      kind: .modified
    )

    let scorer = FileImportanceScorer()
    let scored = scorer.scoreFiles([protocolFile, regularFile])

    #expect(scored[0].file.path == "Sources/App/Conformance.swift")
  }

  @Test("Multiple factors combine additively")
  func multipleFactorsCombine() {
    // Type definition + new file + high changes
    let importantFile = makeFileSummary(
      path: "Sources/App/NewModel.swift",
      changeHints: ["type definition", "protocol conformance"],
      kind: .added,
      additions: 100,
      deletions: 0
    )

    // Test file + generated + small changes
    let unimportantFile = makeFileSummary(
      path: "Tests/Generated/MockTests.swift",
      changeHints: ["test changes"],
      kind: .modified,
      additions: 5,
      deletions: 2,
      isGenerated: true
    )

    let scorer = FileImportanceScorer()
    let scores = scorer.scoresByPath([importantFile, unimportantFile])

    let importantScore = scores["Sources/App/NewModel.swift"]!
    let unimportantScore = scores["Tests/Generated/MockTests.swift"]!

    // Important file should score much higher
    #expect(importantScore > unimportantScore + 50)
  }

  private func makeFileSummary(
    path: String,
    changeHints: [String],
    kind: GitChangeKind,
    additions: Int = 10,
    deletions: Int = 5,
    isGenerated: Bool = false,
    isBinary: Bool = false
  ) -> ChangeSummary.FileSummary {
    ChangeSummary.FileSummary(
      path: path,
      oldPath: nil,
      kind: kind,
      location: .staged,
      additions: additions,
      deletions: deletions,
      snippet: [],
      compactSnippet: [],
      fullSnippet: [],
      snippetMode: .compact,
      snippetTruncated: false,
      isBinary: isBinary,
      diffLineCount: 0,
      diffHasHunks: true,
      isGenerated: isGenerated,
      changeHints: changeHints
    )
  }
}
