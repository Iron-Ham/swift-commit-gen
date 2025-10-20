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
    let summary = try await summarizer.summarize(status: status)

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
    let summary = try await summarizer.summarize(status: status)

    #expect(summary.fileCount == 1)
    #expect(summary.totalAdditions == 1)
    #expect(summary.totalDeletions == 1)
    #expect(summary.files.allSatisfy { $0.location == .staged })
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

  func diffStaged() async throws -> String {
    stagedDiff
  }

  func diffUnstaged() async throws -> String {
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
