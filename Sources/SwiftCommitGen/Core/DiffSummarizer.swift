import Foundation
import FoundationModels

struct ChangeSummary: Hashable, Codable, PromptRepresentable {
  struct FileSummary: Hashable, Codable, PromptRepresentable {
    var path: String
    var oldPath: String?
    var kind: GitChangeKind
    var location: GitChangeLocation
    var additions: Int
    var deletions: Int
    var snippet: [String]
    var snippetTruncated: Bool
    var isBinary: Bool
    var diffLineCount: Int
    var diffHasHunks: Bool
  var isGenerated: Bool

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
        return "(staged)"
      case .unstaged:
        return "(unstaged)"
      case .untracked:
        return "(untracked)"
      }
    }

    var promptRepresentation: Prompt {
      Prompt {
        "- \(identifier) [\(kind.description); \(scopeLabel(for: location)); +\(additions)/-\(deletions)]"

        for note in detailNotes {
          "  note: \(note)"
        }

        if shouldRenderSnippet {
          for line in snippet {
            "  \(line)"
          }
        } else if !hasExplicitNote {
          "  note: diff omitted (summarize intent in subject/body)."
        }
      }
    }

    func estimatedPromptLineCount() -> Int {
      var lines = 1 // header line per file
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
      additions + deletions >= Self.largeChangeThreshold || diffLineCount >= Self.largeDiffLineThreshold
    }

    private var shouldRenderSnippet: Bool {
      guard !isBinary else { return false }
      guard !isGenerated else { return false }
      guard !diffIsLarge else { return false }
      guard !snippet.isEmpty else { return false }
      return true
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
      "Changes:"

      if files.isEmpty {
        "- No file details captured."
      } else {
        for file in files {
          file
          ""
        }
      }
    }
  }
}

protocol DiffSummarizer {
  func summarize(status: GitStatus, includeStagedOnly: Bool) async throws -> ChangeSummary
}

struct DefaultDiffSummarizer: DiffSummarizer {
  private let gitClient: GitClient
  private let maxLinesPerFile: Int

  init(gitClient: GitClient, maxLinesPerFile: Int = 80) {
    self.gitClient = gitClient
    self.maxLinesPerFile = maxLinesPerFile
  }

  func summarize(status: GitStatus, includeStagedOnly: Bool) async throws -> ChangeSummary {
    var summaries: [ChangeSummary.FileSummary] = []

    let stagedDiff = status.staged.isEmpty ? [:] : parseDiff(try await gitClient.diffStaged())
    let unstagedDiff =
      includeStagedOnly || status.unstaged.isEmpty
      ? [:] : parseDiff(try await gitClient.diffUnstaged())

    let scopedChanges: [GitFileChange]
    if includeStagedOnly {
      scopedChanges = status.staged
    } else {
      scopedChanges = status.staged + status.unstaged + status.untracked
    }

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
      case .unstaged:
        diffInfo = unstagedDiff[change.path] ?? unstagedDiff[change.oldPath ?? ""]
      case .untracked:
        diffInfo = nil
      }

      let additions = diffInfo?.additions ?? 0
      let deletions = diffInfo?.deletions ?? 0
      let snippet = diffInfo?.snippet ?? defaultSnippet(for: change)
      let snippetTruncated = diffInfo?.isTruncated ?? false
      let isBinary = diffInfo?.isBinary ?? false
      let lineCount = diffInfo?.lineCount ?? snippet.count
      let hasHunks = diffInfo?.hasHunks ?? false

      let isGenerated = generatedLookup[change.path]
        ?? change.oldPath.flatMap { generatedLookup[$0] }
        ?? false

      var adjustedSnippet = snippet
      var adjustedTruncation = snippetTruncated
      if isGenerated {
        adjustedSnippet = []
        adjustedTruncation = true
      }

      let limitedSnippet = Array(adjustedSnippet.prefix(maxLinesPerFile))
      let truncatedByLimit = adjustedSnippet.count > maxLinesPerFile

      let summary = ChangeSummary.FileSummary(
        path: change.path,
        oldPath: change.oldPath,
        kind: change.kind,
        location: change.location,
        additions: additions,
        deletions: deletions,
        snippet: limitedSnippet,
        snippetTruncated: adjustedTruncation || truncatedByLimit,
        isBinary: isBinary,
        diffLineCount: lineCount,
        diffHasHunks: hasHunks,
        isGenerated: isGenerated
      )
      summaries.append(summary)
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
    var snippet: [String]
    var lineCount: Int
    var isTruncated: Bool
    var isBinary: Bool
    var hasHunks: Bool
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
      let snippet = Array(currentLines.prefix(maxLinesPerFile)).map { String($0.prefix(160)) }
      let isTruncated = lineCount > maxLinesPerFile

      let parsed = ParsedDiff(
        path: stripDiffPrefix(targetPath),
        oldPath: cleanOldPath(currentOldPath),
        additions: additions,
        deletions: deletions,
        snippet: snippet,
        lineCount: lineCount,
        isTruncated: isTruncated,
        isBinary: isBinary,
        hasHunks: hasHunks
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
