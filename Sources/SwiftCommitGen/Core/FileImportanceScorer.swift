import Foundation

/// Represents a file with its computed importance score.
struct ScoredFile: Sendable {
  var file: ChangeSummary.FileSummary
  var score: Int
}

/// Scores files to determine priority for full snippet allocation.
///
/// Higher scores indicate more important files that should receive full snippets
/// when token budget allows. The scoring considers:
/// - Semantic hints (type definitions, protocol conformance)
/// - Change type (new files, deletions are more important)
/// - Change volume
/// - File category (tests, config files are lower priority)
struct FileImportanceScorer {
  /// Scores and sorts files by importance (highest first).
  func scoreFiles(_ files: [ChangeSummary.FileSummary]) -> [ScoredFile] {
    files.map { file in
      ScoredFile(file: file, score: calculateScore(file))
    }.sorted { $0.score > $1.score }
  }

  /// Computes importance scores for files and returns a lookup dictionary.
  func scoresByPath(_ files: [ChangeSummary.FileSummary]) -> [String: Int] {
    var scores: [String: Int] = [:]
    for file in files {
      scores[file.path] = calculateScore(file)
    }
    return scores
  }

  private func calculateScore(_ file: ChangeSummary.FileSummary) -> Int {
    var score = 0

    // === Positive factors (higher = more important) ===

    // Structural changes are high signal
    if file.changeHints.contains("type definition") {
      score += 30
    }
    if file.changeHints.contains("protocol conformance") {
      score += 25
    }
    if file.changeHints.contains("imports") {
      score += 10
    }

    // New files and deletions need context to understand
    switch file.kind {
    case .added:
      score += 20
    case .deleted:
      score += 15
    case .renamed:
      score += 10
    case .copied:
      score += 5
    case .modified, .untracked, .typeChange, .unmerged, .unknown:
      break
    }

    // High change volume indicates importance
    let changeVolume = file.additions + file.deletions
    if changeVolume > 100 {
      score += 20
    } else if changeVolume > 50 {
      score += 10
    } else if changeVolume > 20 {
      score += 5
    }

    // === Negative factors (lower priority) ===

    // Test files are less critical for understanding the main change
    if file.changeHints.contains("test changes") {
      score -= 15
    }

    // Config changes are usually boilerplate
    if file.changeHints.contains("configuration") {
      score -= 10
    }

    // Generated and binary files provide little LLM value
    if file.isGenerated {
      score -= 50
    }
    if file.isBinary {
      score -= 30
    }

    // Path-based heuristics
    let pathLower = file.path.lowercased()

    // Test directories/files
    if pathLower.contains("test") || pathLower.contains("spec") {
      score -= 10
    }

    // Lock files from package managers
    if pathLower.contains(".lock") || pathLower.contains("package-lock") {
      score -= 40
    }

    // Documentation files
    if pathLower.hasSuffix(".md") || pathLower.hasSuffix(".txt") {
      score -= 5
    }

    // Snapshot/fixture files
    if pathLower.contains("snapshot") || pathLower.contains("fixture") {
      score -= 20
    }

    // Migration files (often boilerplate)
    if pathLower.contains("migration") {
      score -= 10
    }

    // Entry points and main files are important
    if pathLower.contains("main.") || pathLower.contains("app.") {
      score += 15
    }

    // Protocol/interface files
    if pathLower.contains("protocol") || pathLower.contains("interface") {
      score += 10
    }

    return score
  }
}
