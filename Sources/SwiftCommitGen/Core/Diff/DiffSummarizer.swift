import Foundation

struct ChangeSummary {
  struct FileSummary {
    var path: String
    var oldPath: String?
    var kind: GitChangeKind
    var location: GitChangeLocation
    var additions: Int
    var deletions: Int
    var snippet: [String]

    var label: String {
      "\(kind.description.capitalized) \(locationLabel)"
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

      let summary = ChangeSummary.FileSummary(
        path: change.path,
        oldPath: change.oldPath,
        kind: change.kind,
        location: change.location,
        additions: additions,
        deletions: deletions,
        snippet: Array(snippet.prefix(maxLinesPerFile))
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
      let snippet = Array(currentLines.prefix(maxLinesPerFile)).map { String($0.prefix(160)) }

      let parsed = ParsedDiff(
        path: stripDiffPrefix(targetPath),
        oldPath: cleanOldPath(currentOldPath),
        additions: additions,
        deletions: deletions,
        snippet: snippet
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
