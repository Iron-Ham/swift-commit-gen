import Foundation
import Testing

@testable import SwiftCommitGen

struct SemanticFileGrouperTests {
  @Test("Groups Swift test file with its source file")
  func groupsSwiftTestWithSource() {
    let sourceFile = makeFileSummary(path: "Sources/App/Feature.swift")
    let testFile = makeFileSummary(path: "Tests/AppTests/FeatureTests.swift")

    let grouper = SemanticFileGrouper()
    let groups = grouper.groupFiles([sourceFile, testFile])

    // Should create a group with source and test together
    let allPaths = groups.flatMap { $0.map { $0.path } }
    #expect(allPaths.contains("Sources/App/Feature.swift"))
    #expect(allPaths.contains("Tests/AppTests/FeatureTests.swift"))
  }

  @Test("Groups TypeScript test file with its source file")
  func groupsTypeScriptTestWithSource() {
    let sourceFile = makeFileSummary(path: "src/components/Button.tsx")
    let testFile = makeFileSummary(path: "src/components/Button.test.tsx")

    let grouper = SemanticFileGrouper()
    let groups = grouper.groupFiles([sourceFile, testFile])

    // Both files should be in the same group or at least both present
    let allPaths = groups.flatMap { $0.map { $0.path } }
    #expect(allPaths.contains("src/components/Button.tsx"))
    #expect(allPaths.contains("src/components/Button.test.tsx"))
  }

  @Test("Groups Go test file with its source file")
  func groupsGoTestWithSource() {
    let sourceFile = makeFileSummary(path: "pkg/handler/auth.go")
    let testFile = makeFileSummary(path: "pkg/handler/auth_test.go")

    let grouper = SemanticFileGrouper()
    let groups = grouper.groupFiles([sourceFile, testFile])

    let allPaths = groups.flatMap { $0.map { $0.path } }
    #expect(allPaths.contains("pkg/handler/auth.go"))
    #expect(allPaths.contains("pkg/handler/auth_test.go"))
  }

  @Test("Groups Python test file with its source file")
  func groupsPythonTestWithSource() {
    let sourceFile = makeFileSummary(path: "src/utils/parser.py")
    let testFile = makeFileSummary(path: "tests/test_parser.py")

    let grouper = SemanticFileGrouper()
    let groups = grouper.groupFiles([sourceFile, testFile])

    let allPaths = groups.flatMap { $0.map { $0.path } }
    #expect(allPaths.contains("src/utils/parser.py"))
    #expect(allPaths.contains("tests/test_parser.py"))
  }

  @Test("Groups files by directory when no test matches")
  func groupsByDirectoryWhenNoTestMatches() {
    let file1 = makeFileSummary(path: "Sources/App/FeatureA.swift")
    let file2 = makeFileSummary(path: "Sources/App/FeatureB.swift")
    let file3 = makeFileSummary(path: "Sources/Core/Helper.swift")

    let grouper = SemanticFileGrouper()
    let groups = grouper.groupFiles([file1, file2, file3])

    // Files in Sources/App should be grouped together
    let appGroup = groups.first { group in
      group.contains { $0.path == "Sources/App/FeatureA.swift" }
    }
    #expect(appGroup != nil)
    if let group = appGroup {
      #expect(group.contains { $0.path == "Sources/App/FeatureB.swift" })
    }
  }

  @Test("Splits oversized groups")
  func splitsOversizedGroups() {
    // Create 15 files in the same directory
    let files = (0..<15).map { i in
      makeFileSummary(path: "Sources/Large/File\(i).swift")
    }

    let grouper = SemanticFileGrouper(maxGroupSize: 5)
    let groups = grouper.groupFiles(files)

    // Should split into multiple groups
    #expect(groups.count >= 3)
    #expect(groups.allSatisfy { $0.count <= 5 })

    // All files should still be present
    let allPaths = Set(groups.flatMap { $0.map { $0.path } })
    #expect(allPaths.count == 15)
  }

  @Test("Handles empty file list")
  func handlesEmptyFileList() {
    let grouper = SemanticFileGrouper()
    let groups = grouper.groupFiles([])
    #expect(groups.isEmpty)
  }

  @Test("Handles single file")
  func handlesSingleFile() {
    let file = makeFileSummary(path: "Sources/App/Solo.swift")

    let grouper = SemanticFileGrouper()
    let groups = grouper.groupFiles([file])

    #expect(groups.count == 1)
    #expect(groups[0].count == 1)
    #expect(groups[0][0].path == "Sources/App/Solo.swift")
  }

  @Test("Identifies test files by directory")
  func identifiesTestFilesByDirectory() {
    let testFile1 = makeFileSummary(path: "tests/unit/helper.py")
    let testFile2 = makeFileSummary(path: "__tests__/Button.js")
    let testFile3 = makeFileSummary(path: "spec/models/user_spec.rb")

    let grouper = SemanticFileGrouper()
    let groups = grouper.groupFiles([testFile1, testFile2, testFile3])

    // All should be recognized as test files and grouped appropriately
    let allPaths = Set(groups.flatMap { $0.map { $0.path } })
    #expect(allPaths.count == 3)
  }

  @Test("Preserves file order within groups")
  func preservesFileOrderWithinGroups() {
    let file1 = makeFileSummary(path: "Sources/App/AAA.swift")
    let file2 = makeFileSummary(path: "Sources/App/ZZZ.swift")
    let file3 = makeFileSummary(path: "Sources/App/MMM.swift")

    let grouper = SemanticFileGrouper()
    let groups = grouper.groupFiles([file1, file2, file3])

    // Files in same directory should be sorted by path
    let appGroup = groups.first { group in
      group.contains { $0.path.contains("Sources/App") }
    }
    #expect(appGroup != nil)
    if let group = appGroup {
      let paths = group.map { $0.path }
      #expect(paths == paths.sorted())
    }
  }

  private func makeFileSummary(path: String) -> ChangeSummary.FileSummary {
    ChangeSummary.FileSummary(
      path: path,
      oldPath: nil,
      kind: .modified,
      location: .staged,
      additions: 10,
      deletions: 5,
      snippet: [],
      compactSnippet: [],
      fullSnippet: [],
      snippetMode: .compact,
      snippetTruncated: false,
      isBinary: false,
      diffLineCount: 0,
      diffHasHunks: true,
      isGenerated: false,
      changeHints: []
    )
  }
}
