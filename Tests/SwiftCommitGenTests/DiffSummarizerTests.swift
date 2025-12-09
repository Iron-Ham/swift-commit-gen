import Foundation
import Testing

@testable import SwiftCommitGen

struct DiffSummarizerTests {
  @Test("Summarizes staged changes with diff statistics")
  func summarizesStagedChanges() async throws {
    let change = GitFileChange(
      path: "Sources/App/File.swift",
      oldPath: nil,
      kind: .modified,
      location: .staged
    )

    let status = GitStatus(staged: [change], unstaged: [], untracked: [])

    let diff = """
      diff --git a/Sources/App/File.swift b/Sources/App/File.swift
      index 1111111..2222222 100644
      --- a/Sources/App/File.swift
      +++ b/Sources/App/File.swift
      @@ -1,3 +1,3 @@
      -let value = 1
      +let value = 2
       print(value)
      """

    let client = MockGitClient(
      root: URL(fileURLWithPath: "/tmp/demo"),
      status: status,
      stagedDiff: diff,
      unstagedDiff: ""
    )

    let summarizer = DefaultDiffSummarizer(gitClient: client, maxLinesPerFile: 10)
    let summary = try await summarizer.summarize(status: status, diffOptions: .default)

    #expect(summary.fileCount == 1)
    #expect(summary.totalAdditions == 1)
    #expect(summary.totalDeletions == 1)

    let fileSummary = summary.files.first
    #expect(fileSummary?.path == "Sources/App/File.swift")
    #expect(fileSummary?.label.contains("staged") == true)
    #expect(fileSummary?.snippet.isEmpty == false)
  }

  @Test("Ignores unstaged and untracked changes")
  func ignoresUnstagedAndUntracked() async throws {
    let staged = GitFileChange(
      path: "Sources/App/Staged.swift",
      oldPath: nil,
      kind: .modified,
      location: .staged
    )
    let unstaged = GitFileChange(
      path: "Sources/App/Working.swift",
      oldPath: nil,
      kind: .modified,
      location: .unstaged
    )
    let untracked = GitFileChange(
      path: "Docs/Notes.md",
      oldPath: nil,
      kind: .untracked,
      location: .untracked
    )

    let status = GitStatus(staged: [staged], unstaged: [unstaged], untracked: [untracked])

    let stagedDiff = """
      diff --git a/Sources/App/Staged.swift b/Sources/App/Staged.swift
      --- a/Sources/App/Staged.swift
      +++ b/Sources/App/Staged.swift
      @@
      -old
      +new
      """

    let unstagedDiff = """
      diff --git a/Sources/App/Working.swift b/Sources/App/Working.swift
      --- a/Sources/App/Working.swift
      +++ b/Sources/App/Working.swift
      @@
      -alpha
      +beta
      """

    let client = MockGitClient(
      root: URL(fileURLWithPath: "/tmp/demo"),
      status: status,
      stagedDiff: stagedDiff,
      unstagedDiff: unstagedDiff
    )

    let summarizer = DefaultDiffSummarizer(gitClient: client, maxLinesPerFile: 10)
    let summary = try await summarizer.summarize(status: status, diffOptions: .default)

    #expect(summary.fileCount == 1)
    #expect(summary.totalAdditions == 1)
    #expect(summary.totalDeletions == 1)
    #expect(summary.files.allSatisfy { $0.location == .staged })
  }

  @Test("Smart snippet selection prioritizes changes over context")
  func smartSnippetPrioritizesChanges() async throws {
    let change = GitFileChange(
      path: "Sources/App/Large.swift",
      oldPath: nil,
      kind: .modified,
      location: .staged
    )

    let status = GitStatus(staged: [change], unstaged: [], untracked: [])

    // Create a diff with lots of context and changes scattered throughout
    let diff = """
      diff --git a/Sources/App/Large.swift b/Sources/App/Large.swift
      --- a/Sources/App/Large.swift
      +++ b/Sources/App/Large.swift
      @@ -10,20 +10,25 @@ func calculateTotal() {
       let a = 1
       let b = 2
       let c = 3
       let d = 4
       let e = 5
      -let oldValue = 10
      +let newValue = 20
       let f = 6
       let g = 7
       let h = 8
       let i = 9
       let j = 10
      @@ -50,10 +55,15 @@ func anotherFunction() {
       let x = 100
       let y = 200
      +let added = 300
       let z = 400
      """

    let client = MockGitClient(
      root: URL(fileURLWithPath: "/tmp/demo"),
      status: status,
      stagedDiff: diff,
      unstagedDiff: ""
    )

    // Use a small maxLines to force smart selection
    let summarizer = DefaultDiffSummarizer(gitClient: client, maxLinesPerFile: 8)
    let summary = try await summarizer.summarize(status: status, diffOptions: .default)

    let fileSummary = summary.files.first
    #expect(fileSummary != nil)

    let snippet = fileSummary!.snippet

    // Should include hunk headers
    #expect(snippet.contains { $0.contains("@@") })

    // Should include actual changes
    #expect(
      snippet.contains {
        $0.contains("-let oldValue") || $0.contains("+let newValue") || $0.contains("+let added")
      }
    )

    // Should NOT be just the first N lines (which would be mostly context)
    // The first few lines after the hunk header are context, not changes
    #expect(!snippet.allSatisfy { !$0.hasPrefix("+") && !$0.hasPrefix("-") || $0.hasPrefix("@@") })
  }

  @Test("Smart snippet includes ellipsis for skipped sections")
  func smartSnippetIncludesEllipsis() async throws {
    let change = GitFileChange(
      path: "Sources/App/Scattered.swift",
      oldPath: nil,
      kind: .modified,
      location: .staged
    )

    let status = GitStatus(staged: [change], unstaged: [], untracked: [])

    // Diff with changes far apart
    let diff = """
      diff --git a/Sources/App/Scattered.swift b/Sources/App/Scattered.swift
      --- a/Sources/App/Scattered.swift
      +++ b/Sources/App/Scattered.swift
      @@ -1,5 +1,5 @@
      -first change
      +FIRST CHANGE
       context1
       context2
       context3
       context4
       context5
       context6
       context7
       context8
       context9
       context10
      -second change
      +SECOND CHANGE
      """

    let client = MockGitClient(
      root: URL(fileURLWithPath: "/tmp/demo"),
      status: status,
      stagedDiff: diff,
      unstagedDiff: ""
    )

    let summarizer = DefaultDiffSummarizer(gitClient: client, maxLinesPerFile: 10)
    let summary = try await summarizer.summarize(status: status, diffOptions: .default)

    let fileSummary = summary.files.first
    #expect(fileSummary != nil)

    let snippet = fileSummary!.snippet

    // Should include both changes
    #expect(snippet.contains { $0.contains("FIRST") })
    #expect(snippet.contains { $0.contains("SECOND") })

    // Should include ellipsis marker for skipped context
    #expect(snippet.contains { $0.contains("...") })
  }
}

private struct MockGitClient: GitClient {
  var root: URL
  var status: GitStatus
  var stagedDiff: String
  var unstagedDiff: String

  func repositoryRoot() async throws -> URL {
    root
  }

  func status() async throws -> GitStatus {
    status
  }

  func diffStaged(options: DiffOptions) async throws -> String {
    stagedDiff
  }

  func diffUnstaged(options: DiffOptions) async throws -> String {
    unstagedDiff
  }

  func listChangedFiles(scope: GitChangeScope) async throws -> [GitFileChange] {
    status.changes(for: scope)
  }

  func currentBranch() async throws -> String {
    "main"
  }

  func stage(paths: [String]) async throws {}

  func stageAll() async throws {}

  func commit(message: String) async throws {}

  func generatedFileHints(for paths: [String]) async throws -> [String: Bool] {
    [:]
  }
}
