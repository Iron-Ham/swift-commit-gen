import Foundation
import FoundationModels

/// Represents the staged changes that will be summarized for prompt construction.
struct ChangeSummary: Hashable, Codable, PromptRepresentable {
  /// Describes how a single file contributes to the change summary and prompt content.
  struct FileSummary: Hashable, Codable, PromptRepresentable {
    enum SnippetMode: String, Codable {
      case compact
      case full
    }

    var path: String
    var oldPath: String?
    var kind: GitChangeKind
    var location: GitChangeLocation
    var additions: Int
    var deletions: Int
    var snippet: [String]
    var compactSnippet: [String]
    var fullSnippet: [String]
    var snippetMode: SnippetMode
    var snippetTruncated: Bool
    var isBinary: Bool
    var diffLineCount: Int
    var diffHasHunks: Bool
    var isGenerated: Bool
    /// Semantic hints about what kind of changes were made (e.g., "function signature", "imports")
    var changeHints: [String] = []

    var label: String {
      "\(kind.description.capitalized) \(locationLabel)"
    }

    private var identifier: String {
      if let old = oldPath, old != path {
        "\(old) -> \(path)"
      } else {
        path
      }
    }

    private var locationLabel: String {
      switch location {
      case .staged:
        "(staged)"
      case .unstaged:
        "(unstaged)"
      case .untracked:
        "(untracked)"
      }
    }

    var promptRepresentation: Prompt {
      Prompt {
        for line in promptLines() {
          line
        }
      }
    }

    func estimatedPromptLineCount() -> Int {
      var lines = 1  // header line per file
      lines += detailNotes.count

      if shouldRenderSnippet {
        lines += snippet.count
      } else if !hasExplicitNote {
        lines += 1
      }

      return lines
    }

    private static let largeChangeThreshold = 400
    private static let largeDiffLineThreshold = 200

    private var diffIsLarge: Bool {
      additions + deletions >= Self.largeChangeThreshold
        || diffLineCount >= Self.largeDiffLineThreshold
    }

    private var shouldRenderSnippet: Bool {
      if isBinary || isGenerated || diffIsLarge || snippet.isEmpty {
        false
      } else {
        true
      }
    }

    private var hasExplicitNote: Bool {
      !detailNotes.isEmpty
    }

    private var detailNotes: [String] {
      var notes: [String] = []

      if kind == .added {
        notes.append("new file")
      }

      if kind == .deleted {
        notes.append("entire file removed")
      }

      if kind == .renamed, let old = oldPath {
        if diffHasHunks {
          notes.append("renamed from \(old)")
        } else {
          notes.append("pure rename from \(old)")
        }
      }

      if kind == .copied, let old = oldPath {
        notes.append("copied from \(old)")
      }

      if isBinary {
        notes.append("binary file; diff omitted")
      }

      if diffIsLarge {
        notes.append("large diff (+\(additions)/-\(deletions))")
      } else if snippetTruncated {
        if snippet.isEmpty {
          notes.append("diff omitted to reduce prompt size")
        } else {
          notes.append("diff truncated to \(snippet.count) lines")
        }
      }

      if !diffHasHunks && kind == .modified {
        notes.append("metadata-only change")
      }

      if isGenerated {
        notes.append("marked as generated file (diff skipped)")
      }

      return notes
    }

    func promptLines() -> [String] {
      var lines: [String] = []
      lines.append(
        "- \(identifier) [\(kind.description); \(scopeLabel(for: location)); +\(additions)/-\(deletions)]"
      )

      // Add semantic change hints if available
      if !changeHints.isEmpty {
        lines.append("  changes: \(changeHints.joined(separator: ", "))")
      }

      for note in detailNotes {
        lines.append("  note: \(note)")
      }

      if shouldRenderSnippet {
        for line in snippet {
          lines.append("  \(line)")
        }
      } else if !hasExplicitNote {
        lines.append("  note: diff omitted (summarize intent in subject/body).")
      }

      return lines
    }

    func withSnippetMode(_ mode: SnippetMode) -> FileSummary {
      var copy = self
      copy.applySnippetMode(mode)
      return copy
    }

    mutating func applySnippetMode(_ mode: SnippetMode) {
      let wasTruncated = snippetTruncated
      snippetMode = mode
      switch mode {
      case .compact:
        snippet = compactSnippet
      case .full:
        snippet = fullSnippet
      }
      snippetTruncated = wasTruncated || diffLineCount > snippet.count
    }
  }

  var files: [FileSummary]

  var totalAdditions: Int {
    files.reduce(0) { $0 + $1.additions }
  }

  var totalDeletions: Int {
    files.reduce(0) { $0 + $1.deletions }
  }

  var fileCount: Int {
    files.count
  }

  var promptRepresentation: Prompt {
    Prompt {
      for line in promptLines() {
        line
      }
    }
  }
}

extension ChangeSummary {
  func promptLines() -> [String] {
    var lines: [String] = ["Changes:"]

    if files.isEmpty {
      lines.append("- No file details captured.")
      return lines
    }

    for (index, file) in files.enumerated() {
      lines.append(contentsOf: file.promptLines())
      if index < files.count - 1 {
        lines.append("")
      }
    }

    return lines
  }
}

/// Contract for turning raw Git status information into prompt-ready summaries.
protocol DiffSummarizer {
  func summarize(status: GitStatus, diffOptions: DiffOptions) async throws -> ChangeSummary
}

/// Default implementation that shells out to Git and trims diffs to manageable snippets.
struct DefaultDiffSummarizer: DiffSummarizer {
  private let gitClient: GitClient
  private let maxLinesPerFile: Int
  private let maxFullLinesPerFile: Int

  init(gitClient: GitClient, maxLinesPerFile: Int = 80, maxFullLinesPerFile: Int = 200) {
    self.gitClient = gitClient
    self.maxLinesPerFile = maxLinesPerFile
    self.maxFullLinesPerFile = max(maxLinesPerFile, maxFullLinesPerFile)
  }

  func summarize(status: GitStatus, diffOptions: DiffOptions) async throws -> ChangeSummary {
    var summaries: [ChangeSummary.FileSummary] = []

    let stagedDiff =
      status.staged.isEmpty ? [:] : parseDiff(try await gitClient.diffStaged(options: diffOptions))
    let scopedChanges = status.staged

    var attributePaths: Set<String> = []
    for change in scopedChanges {
      attributePaths.insert(change.path)
      if let old = change.oldPath {
        attributePaths.insert(old)
      }
    }

    let generatedLookup = try await gitClient.generatedFileHints(for: Array(attributePaths))

    for change in scopedChanges {
      let diffInfo: ParsedDiff?
      switch change.location {
      case .staged:
        diffInfo = stagedDiff[change.path] ?? stagedDiff[change.oldPath ?? ""]
      case .unstaged, .untracked:
        diffInfo = nil
      }

      let additions = diffInfo?.additions ?? 0
      let deletions = diffInfo?.deletions ?? 0
      let compactSnippet = diffInfo?.compactSnippet ?? defaultSnippet(for: change)
      let fullSnippet = diffInfo?.fullSnippet ?? compactSnippet
      let snippetTruncated = diffInfo?.isTruncated ?? false
      let isBinary = diffInfo?.isBinary ?? false
      let lineCount = diffInfo?.lineCount ?? compactSnippet.count
      let hasHunks = diffInfo?.hasHunks ?? false
      let changeHints = diffInfo?.changeHints ?? []

      let isGenerated =
        generatedLookup[change.path]
        ?? change.oldPath.flatMap { generatedLookup[$0] }
        ?? false

      var adjustedCompactSnippet = compactSnippet
      var adjustedFullSnippet = fullSnippet
      var adjustedTruncation = snippetTruncated
      if isGenerated {
        adjustedCompactSnippet = []
        adjustedFullSnippet = []
        adjustedTruncation = true
      }

      let limitedCompactSnippet = Array(adjustedCompactSnippet.prefix(maxLinesPerFile))
      let truncatedByLimit = adjustedCompactSnippet.count > maxLinesPerFile
      let limitedFullSnippet = Array(adjustedFullSnippet.prefix(maxFullLinesPerFile))
      let truncatedFullByLimit = adjustedFullSnippet.count > maxFullLinesPerFile

      let summary = ChangeSummary.FileSummary(
        path: change.path,
        oldPath: change.oldPath,
        kind: change.kind,
        location: change.location,
        additions: additions,
        deletions: deletions,
        snippet: limitedCompactSnippet,
        compactSnippet: limitedCompactSnippet,
        fullSnippet: limitedFullSnippet,
        snippetMode: .compact,
        snippetTruncated: adjustedTruncation || truncatedByLimit,
        isBinary: isBinary,
        diffLineCount: lineCount,
        diffHasHunks: hasHunks,
        isGenerated: isGenerated,
        changeHints: changeHints
      )
      var mutableSummary = summary
      if truncatedFullByLimit {
        // ensure flags remain accurate if even the expanded snippet is limited
        mutableSummary.snippetTruncated = true
      }
      mutableSummary.applySnippetMode(ChangeSummary.FileSummary.SnippetMode.compact)
      summaries.append(mutableSummary)
    }

    return ChangeSummary(files: summaries)
  }

  private func defaultSnippet(for change: GitFileChange) -> [String] {
    switch change.location {
    case .untracked:
      return ["(untracked file; diff available after staging)"]
    case .staged, .unstaged:
      switch change.kind {
      case .added:
        return ["(no diff lines captured; new file)"]
      case .deleted:
        return ["(no diff lines captured; file deleted)"]
      default:
        return ["(no diff preview available)"]
      }
    }
  }

  private struct ParsedDiff {
    var path: String
    var oldPath: String?
    var additions: Int
    var deletions: Int
    var compactSnippet: [String]
    var fullSnippet: [String]
    var lineCount: Int
    var isTruncated: Bool
    var isBinary: Bool
    var hasHunks: Bool
    var changeHints: [String]
  }

  /// Analyzes diff lines to extract semantic hints about what kind of changes were made.
  /// This helps the LLM understand the nature of changes beyond just the raw diff.
  ///
  /// Only includes high-signal hints that meaningfully describe the change:
  /// - Structural changes (imports, type definitions, protocol conformance)
  /// - Test file changes
  /// - Configuration file changes
  ///
  /// Excludes low-value hints that describe implementation details rather than intent:
  /// - Generic "function definition" (too common, doesn't add signal)
  /// - "documentation" (comments are ubiquitous)
  /// - "error handling" (too broad, often misleading)
  /// - "property declaration" (too granular)
  private func detectChangeHints(from lines: [String], filePath: String) -> [String] {
    var hints = Set<String>()

    let fileExtension = (filePath as NSString).pathExtension.lowercased()

    // Check for test file context first (high signal)
    let pathLower = filePath.lowercased()
    if pathLower.contains("test") || pathLower.contains("spec") {
      hints.insert("test changes")
    }

    // Check for config file context (high signal)
    let configPatterns = [
      "config", "settings", ".env", "package.json", "Package.swift",
      "Cargo.toml", "requirements.txt", "Gemfile", "pom.xml",
      "build.gradle", "tsconfig", "eslint", "prettier",
    ]
    let fileName = (filePath as NSString).lastPathComponent.lowercased()
    if configPatterns.contains(where: { fileName.contains($0) }) {
      hints.insert("configuration")
    }

    // Analyze changed lines for high-signal patterns
    for line in lines {
      let isAddition = line.hasPrefix("+") && !line.hasPrefix("+++")
      let isDeletion = line.hasPrefix("-") && !line.hasPrefix("---")

      guard isAddition || isDeletion else { continue }

      let content = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)

      // Import changes are high signal - they indicate dependency changes
      if detectsImport(content, fileExtension: fileExtension) {
        hints.insert("imports")
      }

      // Type definitions are high signal - they indicate structural changes
      if detectsTypeDefinition(content, fileExtension: fileExtension) {
        hints.insert("type definition")
      }

      // Protocol/interface conformance is high signal
      if detectsProtocolConformance(content, fileExtension: fileExtension) {
        hints.insert("protocol conformance")
      }
    }

    // Sort for consistent output
    return hints.sorted()
  }

  /// Detects protocol/interface conformance declarations
  private func detectsProtocolConformance(_ content: String, fileExtension: String) -> Bool {
    switch fileExtension {
    case "swift":
      // Look for : ProtocolName or extension Type: Protocol patterns
      return content.contains(": ")
        && (content.hasPrefix("struct ") || content.hasPrefix("class ")
          || content.hasPrefix("enum ") || content.hasPrefix("actor ")
          || content.hasPrefix("extension "))
    case "ts", "tsx":
      return content.contains("implements ") || content.contains("extends ")
    case "java", "kt":
      return content.contains("implements ") || content.contains("extends ")
    case "rs":
      return content.contains("impl ") && content.contains(" for ")
    case "go":
      // Go uses implicit interfaces, hard to detect
      return false
    default:
      return content.contains("implements ") || content.contains("extends ")
    }
  }

  private func detectsImport(_ content: String, fileExtension: String) -> Bool {
    switch fileExtension {
    case "swift":
      return content.hasPrefix("import ")
    case "js", "ts", "jsx", "tsx":
      return content.hasPrefix("import ") || content.contains("require(")
    case "py":
      return content.hasPrefix("import ") || content.hasPrefix("from ")
    case "go":
      return content.hasPrefix("import ") || content.contains("import (")
    case "rs":
      return content.hasPrefix("use ") || content.hasPrefix("extern crate ")
    case "java", "kt", "scala":
      return content.hasPrefix("import ")
    case "rb":
      return content.hasPrefix("require ") || content.hasPrefix("require_relative ")
    default:
      return content.hasPrefix("import ") || content.contains("#include")
    }
  }

  private func detectsTypeDefinition(_ content: String, fileExtension: String) -> Bool {
    switch fileExtension {
    case "swift":
      return content.hasPrefix("class ") || content.hasPrefix("struct ")
        || content.hasPrefix("enum ") || content.hasPrefix("protocol ")
        || content.hasPrefix("extension ") || content.hasPrefix("actor ")
    case "js", "ts", "jsx", "tsx":
      return content.hasPrefix("class ") || content.hasPrefix("interface ")
        || content.hasPrefix("type ") || content.hasPrefix("enum ")
    case "py":
      return content.hasPrefix("class ")
    case "go":
      return content.hasPrefix("type ")
        && (content.contains(" struct") || content.contains(" interface"))
    case "rs":
      return content.hasPrefix("struct ") || content.hasPrefix("enum ")
        || content.hasPrefix("trait ") || content.hasPrefix("impl ")
    case "java", "kt":
      return content.contains("class ") || content.contains("interface ")
        || content.contains("enum ")
    default:
      return content.hasPrefix("class ") || content.hasPrefix("struct ")
    }
  }

  /// Extracts a smart snippet from diff lines, prioritizing actual changes over context.
  ///
  /// Instead of taking the first N lines (which may be mostly context), this function:
  /// 1. Always includes hunk headers (`@@` lines) for function/method context
  /// 2. Prioritizes actual change lines (`+`/`-` prefixed)
  /// 3. Includes minimal surrounding context for each change block
  /// 4. Skips runs of unchanged context in the middle
  ///
  /// - Parameters:
  ///   - lines: The raw diff lines to process
  ///   - maxLines: Maximum number of lines to include in the snippet
  ///   - contextLines: Number of context lines to keep around each change
  /// - Returns: Array of selected lines, truncated to 160 characters each
  private func extractSmartSnippet(
    from lines: [String],
    maxLines: Int,
    contextLines: Int
  ) -> [String] {
    guard !lines.isEmpty, maxLines > 0 else { return [] }

    // If the diff is small enough, just return it all
    if lines.count <= maxLines {
      return lines.map { String($0.prefix(160)) }
    }

    // Identify which lines are "important" (changes or hunk headers)
    var importance = [Bool](repeating: false, count: lines.count)

    for (index, line) in lines.enumerated() {
      // Hunk headers are always important - they show function context
      if line.hasPrefix("@@") {
        importance[index] = true
        continue
      }

      // Actual changes are important
      if line.hasPrefix("+") || line.hasPrefix("-") {
        importance[index] = true

        // Mark surrounding context lines as important too
        for offset in 1...contextLines {
          if index >= offset {
            importance[index - offset] = true
          }
          if index + offset < lines.count {
            importance[index + offset] = true
          }
        }
      }
    }

    // Collect important lines, respecting maxLines budget
    var result: [String] = []
    var lastIncludedIndex: Int? = nil
    var skippedRun = false

    for (index, line) in lines.enumerated() {
      guard importance[index] else {
        skippedRun = true
        continue
      }

      // If we skipped lines and this isn't the first line, add an ellipsis marker
      if skippedRun, let last = lastIncludedIndex, index > last + 1 {
        // Only add ellipsis if we have room and haven't just added one
        if result.count < maxLines - 1 && result.last != "  ..." {
          result.append("  ...")
        }
      }
      skippedRun = false

      // Check if we have room for this line
      if result.count >= maxLines {
        // Add final ellipsis if we're truncating
        if result.last != "  ..." {
          result[result.count - 1] = "  ..."
        }
        break
      }

      result.append(String(line.prefix(160)))
      lastIncludedIndex = index
    }

    // If no important lines found, fall back to first N lines
    if result.isEmpty {
      return Array(lines.prefix(maxLines)).map { String($0.prefix(160)) }
    }

    return result
  }

  private func parseDiff(_ diffText: String) -> [String: ParsedDiff] {
    guard !diffText.isEmpty else { return [:] }

    var results: [String: ParsedDiff] = [:]
    var currentLines: [String] = []
    var currentOldPath: String?
    var currentNewPath: String?

    func finalizeBlock() {
      guard let targetPath = determineTargetPath(newPath: currentNewPath, oldPath: currentOldPath)
      else {
        currentLines.removeAll(keepingCapacity: true)
        currentOldPath = nil
        currentNewPath = nil
        return
      }

      let additions = currentLines.reduce(0) { partial, line in
        line.hasPrefix("+") && !line.hasPrefix("+++") ? partial + 1 : partial
      }
      let deletions = currentLines.reduce(0) { partial, line in
        line.hasPrefix("-") && !line.hasPrefix("---") ? partial + 1 : partial
      }

      let lineCount = currentLines.count
      let hasHunks = currentLines.contains { $0.hasPrefix("@@") }
      let isBinary = currentLines.contains { line in
        let lowercased = line.lowercased()
        return lowercased.hasPrefix("binary files ") || lowercased == "binary files differ"
      }

      // Use smart snippet selection that prioritizes actual changes over context
      let compactSnippet = extractSmartSnippet(
        from: currentLines,
        maxLines: maxLinesPerFile,
        contextLines: 1
      )
      let fullSnippet = extractSmartSnippet(
        from: currentLines,
        maxLines: maxFullLinesPerFile,
        contextLines: 2
      )
      let isTruncated = lineCount > maxFullLinesPerFile

      // Detect semantic change hints from the raw diff lines
      let changeHints = detectChangeHints(from: currentLines, filePath: stripDiffPrefix(targetPath))

      let parsed = ParsedDiff(
        path: stripDiffPrefix(targetPath),
        oldPath: cleanOldPath(currentOldPath),
        additions: additions,
        deletions: deletions,
        compactSnippet: compactSnippet,
        fullSnippet: fullSnippet,
        lineCount: lineCount,
        isTruncated: isTruncated,
        isBinary: isBinary,
        hasHunks: hasHunks,
        changeHints: changeHints
      )

      results[parsed.path] = parsed
      if let old = parsed.oldPath {
        results[old] = parsed
      }

      currentLines.removeAll(keepingCapacity: true)
      currentOldPath = nil
      currentNewPath = nil
    }

    let lines = diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for line in lines {
      if line.hasPrefix("diff --git ") {
        finalizeBlock()
        continue
      }

      if line.hasPrefix("--- ") {
        currentOldPath = String(line.dropFirst(4))
        continue
      }

      if line.hasPrefix("+++ ") {
        currentNewPath = String(line.dropFirst(4))
        continue
      }

      currentLines.append(line)
    }

    finalizeBlock()
    return results
  }

  private func determineTargetPath(newPath: String?, oldPath: String?) -> String? {
    if let newPath, newPath != "/dev/null" {
      return newPath
    }
    return oldPath
  }

  private func stripDiffPrefix(_ path: String) -> String {
    if path == "/dev/null" { return path }
    if path.hasPrefix("a/") || path.hasPrefix("b/") {
      return String(path.dropFirst(2))
    }
    return path
  }

  private func cleanOldPath(_ path: String?) -> String? {
    guard let path else { return nil }
    let stripped = stripDiffPrefix(path)
    return stripped == "/dev/null" ? nil : stripped
  }
}

private func scopeLabel(for location: GitChangeLocation) -> String {
  switch location {
  case .staged:
    return "staged"
  case .unstaged:
    return "unstaged"
  case .untracked:
    return "untracked"
  }
}
