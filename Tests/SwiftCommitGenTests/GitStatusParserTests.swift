import Testing
@testable import SwiftCommitGen

struct GitStatusParserTests {

  @Test("Parses basic porcelain output")
  func parsesBasicPorcelainOutput() {
    let sample = """
    M  Sources/App/File.swift
    AM Sources/App/NewFile.swift
    ?? README.md
    R  OldName.swift -> NewName.swift
    """

    let status = GitStatusParser.parse(sample)

    #expect(status.staged.count == 3)
    #expect(status.unstaged.count == 1)
    #expect(status.untracked.count == 1)
    #expect(status.hasChanges)

    let modified = status.staged.first { $0.path == "Sources/App/File.swift" }
    #expect(modified?.kind == .modified)

    let added = status.staged.first { $0.path == "Sources/App/NewFile.swift" }
    #expect(added?.kind == .added)

    let unstaged = status.unstaged.first { $0.path == "Sources/App/NewFile.swift" }
    #expect(unstaged?.kind == .modified)

    let rename = status.staged.first { $0.kind == .renamed }
    #expect(rename?.oldPath == "OldName.swift")
    #expect(rename?.path == "NewName.swift")

    #expect(status.changes(for: .staged).count == 3)
    #expect(status.changes(for: .unstaged).count == 1)
    #expect(status.changes(for: .all).count == 5)
  }
}
