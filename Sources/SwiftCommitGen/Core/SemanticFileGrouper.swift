import Foundation

/// Groups files by semantic relationships before token-based batching.
///
/// The grouper ensures that semantically related files (like a source file and its tests)
/// are kept together in the same batch when possible, improving the LLM's ability to
/// understand the full context of changes.
struct SemanticFileGrouper {
  /// Maximum files per group to avoid creating batches that are too large.
  var maxGroupSize: Int

  init(maxGroupSize: Int = 8) {
    self.maxGroupSize = max(1, maxGroupSize)
  }

  /// Groups files by semantic relationships.
  ///
  /// Grouping strategy:
  /// 1. Match test files to their source counterparts
  /// 2. Group remaining files by directory
  /// 3. Keep groups under maxGroupSize
  ///
  /// - Parameter files: Files to group
  /// - Returns: Array of file groups, with related files grouped together
  func groupFiles(_ files: [ChangeSummary.FileSummary]) -> [[ChangeSummary.FileSummary]] {
    guard !files.isEmpty else { return [] }

    var filesByPath: [String: ChangeSummary.FileSummary] = [:]
    for file in files {
      filesByPath[file.path] = file
    }

    var assignedPaths = Set<String>()
    var groups: [[ChangeSummary.FileSummary]] = []

    // Phase 1: Match test files to source files
    let (sourceTestGroups, matchedPaths) = matchSourceAndTestFiles(files, filesByPath: filesByPath)
    assignedPaths.formUnion(matchedPaths)
    groups.append(contentsOf: sourceTestGroups)

    // Phase 2: Group remaining files by directory
    let unassignedFiles = files.filter { !assignedPaths.contains($0.path) }
    let directoryGroups = groupByDirectory(unassignedFiles)
    groups.append(contentsOf: directoryGroups)

    // Phase 3: Split oversized groups
    return groups.flatMap { splitGroupIfNeeded($0) }
  }

  // MARK: - Private Implementation

  /// Matches test files to their corresponding source files.
  private func matchSourceAndTestFiles(
    _ files: [ChangeSummary.FileSummary],
    filesByPath: [String: ChangeSummary.FileSummary]
  ) -> (groups: [[ChangeSummary.FileSummary]], matchedPaths: Set<String>) {
    var groups: [[ChangeSummary.FileSummary]] = []
    var matchedPaths = Set<String>()

    // Find all test files
    let testFiles = files.filter { isTestFile($0.path) }

    for testFile in testFiles {
      guard let sourcePath = inferSourcePath(forTest: testFile.path) else { continue }

      // Look for the source file in the changeset
      if let sourceFile = filesByPath[sourcePath], !matchedPaths.contains(sourcePath) {
        // Create a group with source first, then test
        groups.append([sourceFile, testFile])
        matchedPaths.insert(sourcePath)
        matchedPaths.insert(testFile.path)
      }
    }

    return (groups, matchedPaths)
  }

  /// Groups files by their parent directory.
  private func groupByDirectory(
    _ files: [ChangeSummary.FileSummary]
  ) -> [[ChangeSummary.FileSummary]] {
    guard !files.isEmpty else { return [] }

    var byDirectory: [String: [ChangeSummary.FileSummary]] = [:]

    for file in files {
      let dir = parentDirectory(of: file.path)
      byDirectory[dir, default: []].append(file)
    }

    // Sort directories for deterministic output
    let sortedDirs = byDirectory.keys.sorted()
    return sortedDirs.compactMap { dir -> [ChangeSummary.FileSummary]? in
      guard let files = byDirectory[dir], !files.isEmpty else { return nil }
      // Sort files within directory by path for consistency
      return files.sorted { $0.path < $1.path }
    }
  }

  /// Splits a group if it exceeds maxGroupSize.
  private func splitGroupIfNeeded(
    _ group: [ChangeSummary.FileSummary]
  ) -> [[ChangeSummary.FileSummary]] {
    guard group.count > maxGroupSize else { return [group] }

    var result: [[ChangeSummary.FileSummary]] = []
    var currentChunk: [ChangeSummary.FileSummary] = []

    for file in group {
      currentChunk.append(file)
      if currentChunk.count >= maxGroupSize {
        result.append(currentChunk)
        currentChunk = []
      }
    }

    if !currentChunk.isEmpty {
      result.append(currentChunk)
    }

    return result
  }

  /// Determines if a file path represents a test file.
  private func isTestFile(_ path: String) -> Bool {
    let lowercased = path.lowercased()
    let filename = (path as NSString).lastPathComponent.lowercased()
    let filenameWithoutExt = (filename as NSString).deletingPathExtension

    // Directory-based detection
    if lowercased.contains("/tests/") || lowercased.contains("/test/")
      || lowercased.contains("/__tests__/") || lowercased.contains("/spec/")
    {
      return true
    }

    // Filename pattern detection
    // Swift: FooTests.swift, FooTest.swift
    if filenameWithoutExt.hasSuffix("tests") || filenameWithoutExt.hasSuffix("test") {
      return true
    }

    // JavaScript/TypeScript: foo.test.ts, foo.spec.ts
    if filename.contains(".test.") || filename.contains(".spec.") {
      return true
    }

    // Python: test_foo.py
    if filenameWithoutExt.hasPrefix("test_") {
      return true
    }

    // Go: foo_test.go
    if filenameWithoutExt.hasSuffix("_test") {
      return true
    }

    return false
  }

  /// Infers the source file path for a given test file path.
  private func inferSourcePath(forTest testPath: String) -> String? {
    let filename = (testPath as NSString).lastPathComponent
    let directory = (testPath as NSString).deletingLastPathComponent
    let ext = (filename as NSString).pathExtension
    let nameWithoutExt = (filename as NSString).deletingPathExtension

    var inferredSourceName: String?

    // Swift: FooTests.swift -> Foo.swift, FooTest.swift -> Foo.swift
    if nameWithoutExt.hasSuffix("Tests") {
      inferredSourceName = String(nameWithoutExt.dropLast(5))
    } else if nameWithoutExt.hasSuffix("Test") {
      inferredSourceName = String(nameWithoutExt.dropLast(4))
    }
    // JavaScript/TypeScript: foo.test.ts -> foo.ts, foo.spec.ts -> foo.ts
    else if nameWithoutExt.hasSuffix(".test") {
      inferredSourceName = String(nameWithoutExt.dropLast(5))
    } else if nameWithoutExt.hasSuffix(".spec") {
      inferredSourceName = String(nameWithoutExt.dropLast(5))
    }
    // Python: test_foo.py -> foo.py
    else if nameWithoutExt.hasPrefix("test_") {
      inferredSourceName = String(nameWithoutExt.dropFirst(5))
    }
    // Go: foo_test.go -> foo.go
    else if nameWithoutExt.hasSuffix("_test") {
      inferredSourceName = String(nameWithoutExt.dropLast(5))
    }

    guard let sourceName = inferredSourceName, !sourceName.isEmpty else { return nil }

    // Try to find source in corresponding source directory
    let sourceFilename = ext.isEmpty ? sourceName : "\(sourceName).\(ext)"

    // Common test→source directory mappings
    let sourceDirectoryMappings = [
      "Tests": "Sources",
      "tests": "src",
      "test": "src",
      "__tests__": "",
      "spec": "lib",
    ]

    // Try mapped directories first
    for (testDir, sourceDir) in sourceDirectoryMappings {
      if directory.contains("/\(testDir)/") || directory.contains("/\(testDir)") {
        let mappedDir = directory.replacingOccurrences(of: "/\(testDir)/", with: "/\(sourceDir)/")
          .replacingOccurrences(of: "/\(testDir)", with: sourceDir.isEmpty ? "" : "/\(sourceDir)")
        let candidatePath = (mappedDir as NSString).appendingPathComponent(sourceFilename)
        return candidatePath
      }
    }

    // Fallback: assume source is in same directory
    return (directory as NSString).appendingPathComponent(sourceFilename)
  }

  /// Returns the parent directory of a path.
  private func parentDirectory(of path: String) -> String {
    let dir = (path as NSString).deletingLastPathComponent
    return dir.isEmpty ? "." : dir
  }
}
