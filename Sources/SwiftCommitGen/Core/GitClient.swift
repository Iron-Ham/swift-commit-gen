import Foundation

/// Indicates which staging area slice a Git query should inspect.
enum GitChangeScope: Hashable, Codable {
  case staged
  case unstaged
  case all
}

/// Represents the staging state for a single changed file.
enum GitChangeLocation: Hashable, Codable {
  case staged
  case unstaged
  case untracked
}

/// Categorizes the type of change reported by Git status output.
enum GitChangeKind: String, Hashable, Codable {
  case added = "A"
  case modified = "M"
  case deleted = "D"
  case renamed = "R"
  case copied = "C"
  case typeChange = "T"
  case unmerged = "U"
  case untracked = "?"
  case unknown = "-"  // default fallback

  var description: String {
    switch self {
    case .added:
      "added"
    case .modified:
      "modified"
    case .deleted:
      "deleted"
    case .renamed:
      "renamed"
    case .copied:
      "copied"
    case .typeChange:
      "type change"
    case .unmerged:
      "unmerged"
    case .untracked:
      "untracked"
    case .unknown:
      "unknown"
    }
  }

  init(statusCode: Character) {
    switch statusCode {
    case "A":
      self = .added
    case "M":
      self = .modified
    case "D":
      self = .deleted
    case "R":
      self = .renamed
    case "C":
      self = .copied
    case "T":
      self = .typeChange
    case "U":
      self = .unmerged
    case "?":
      self = .untracked
    default:
      self = .unknown
    }
  }
}

/// Snapshot of a file-level change derived from `git status` output.
struct GitFileChange {
  var path: String
  var oldPath: String?
  var kind: GitChangeKind
  var location: GitChangeLocation

  var displayPath: String {
    if let oldPath {
      "\(oldPath) -> \(path)"
    } else {
      path
    }
  }

  var summary: String {
    "[\(kind.rawValue)] \(displayPath)"
  }
}

/// Aggregated staging information for the repository.
struct GitStatus {
  var staged: [GitFileChange] = []
  var unstaged: [GitFileChange] = []
  var untracked: [GitFileChange] = []

  var hasChanges: Bool {
    !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty
  }

  func changes(for scope: GitChangeScope) -> [GitFileChange] {
    switch scope {
    case .staged:
      staged
    case .unstaged:
      unstaged
    case .all:
      staged + unstaged + untracked
    }
  }
}

/// Minimal surface area required to interrogate Git for commit generation.
protocol GitClient {
  func repositoryRoot() async throws -> URL
  func status() async throws -> GitStatus
  func diffStaged(options: DiffOptions) async throws -> String
  func diffUnstaged(options: DiffOptions) async throws -> String
  func listChangedFiles(scope: GitChangeScope) async throws -> [GitFileChange]
  func currentBranch() async throws -> String
  func stage(paths: [String]) async throws
  func stageAll() async throws
  func commit(message: String) async throws
  func generatedFileHints(for paths: [String]) async throws -> [String: Bool]
}

/// Shell-based Git client that proxies calls through `/usr/bin/env git`.
struct SystemGitClient: GitClient {
  private let fileManager: FileManager
  private let workingDirectory: URL

  init(fileManager: FileManager = .default, workingDirectory: URL? = nil) {
    self.fileManager = fileManager
    if let workingDirectory {
      self.workingDirectory = workingDirectory
    } else {
      self.workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    }
  }

  func repositoryRoot() async throws -> URL {
    let output = try runGit(["rev-parse", "--show-toplevel"])
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw CommitGenError.gitRepositoryUnavailable
    }
    return URL(fileURLWithPath: trimmed)
  }

  func status() async throws -> GitStatus {
    _ = try await repositoryRoot()
    let output = try runGit(["status", "--porcelain"])
    return GitStatusParser.parse(output)
  }

  func diffStaged(options: DiffOptions) async throws -> String {
    _ = try await repositoryRoot()
    return try runGit(buildDiffArgs(staged: true, options: options))
  }

  func diffUnstaged(options: DiffOptions) async throws -> String {
    _ = try await repositoryRoot()
    return try runGit(buildDiffArgs(staged: false, options: options))
  }

  private func buildDiffArgs(staged: Bool, options: DiffOptions) -> [String] {
    var args = ["diff"]
    if staged {
      args.append("--cached")
    }
    args.append("--no-color")
    if options.useFunctionContext {
      args.append("--function-context")
    }
    if options.detectRenamesCopies {
      args.append(contentsOf: ["-M", "-C"])
    }
    if let contextLines = options.contextLines {
      args.append("-U\(contextLines)")
    }
    return args
  }

  func listChangedFiles(scope: GitChangeScope) async throws -> [GitFileChange] {
    let status = try await status()
    return status.changes(for: scope)
  }

  func currentBranch() async throws -> String {
    _ = try await repositoryRoot()
    let output = try runGit(["rev-parse", "--abbrev-ref", "HEAD"])
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "HEAD" : trimmed
  }

  func stage(paths: [String]) async throws {
    guard !paths.isEmpty else { return }
    _ = try await repositoryRoot()
    _ = try runGit(["add", "--"] + paths)
  }

  func stageAll() async throws {
    _ = try await repositoryRoot()
    _ = try runGit(["add", "--all"])
  }

  func commit(message: String) async throws {
    _ = try await repositoryRoot()

    var formatted = message
    if !formatted.hasSuffix("\n") {
      formatted.append("\n")
    }

    let tempURL = fileManager.temporaryDirectory.appendingPathComponent(
      "scg-\(UUID().uuidString).txt"
    )
    defer { try? fileManager.removeItem(at: tempURL) }

    try formatted.write(to: tempURL, atomically: true, encoding: .utf8)
    _ = try runGit(["commit", "-F", tempURL.path])
  }

  func generatedFileHints(for paths: [String]) async throws -> [String: Bool] {
    guard !paths.isEmpty else { return [:] }
    _ = try await repositoryRoot()
    let output = try runGit(["check-attr", "linguist-generated", "--"] + paths)

    var result: [String: Bool] = [:]
    let lines = output.split(whereSeparator: \.isNewline)
    for rawLine in lines {
      let components = rawLine.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      guard components.count == 3 else { continue }
      let path = components[0]
      let value = components[2].lowercased()

      let isGenerated: Bool
      switch value {
      case "true", "set", "1", "yes", "on":
        isGenerated = true
      default:
        isGenerated = false
      }

      result[path] = isGenerated
    }

    return result
  }

  private func runGit(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = workingDirectory

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    process.environment = environment

    do {
      try process.run()
    } catch {
      throw CommitGenError.gitCommandFailed(message: error.localizedDescription)
    }

    // IMPORTANT: Read from pipes BEFORE waiting for exit to avoid deadlock.
    // If the output exceeds the pipe buffer (~64KB), the process will block
    // waiting to write more data, causing a deadlock if we wait for exit first.
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let stderr = String(data: stderrData, encoding: .utf8) ?? ""
      let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw CommitGenError.gitCommandFailed(message: message)
    }

    return String(data: stdoutData, encoding: .utf8) ?? ""
  }
}

struct GitStatusParser {
  static func parse(_ raw: String) -> GitStatus {
    var staged: [GitFileChange] = []
    var unstaged: [GitFileChange] = []
    var untracked: [GitFileChange] = []

    let lines = raw.split(whereSeparator: \.isNewline)
    for rawLine in lines {
      let line = String(rawLine)
      guard line.count >= 3 else { continue }

      let xIndex = line.startIndex
      let yIndex = line.index(after: xIndex)
      let pathIndex = line.index(xIndex, offsetBy: 3)

      let xStatus = line[xIndex]
      let yStatus = line[yIndex]
      let remainder = String(line[pathIndex...])

      if xStatus == "?" && yStatus == "?" {
        let split = splitPath(remainder)
        untracked.append(
          GitFileChange(
            path: split.newPath,
            oldPath: split.oldPath,
            kind: .untracked,
            location: .untracked
          )
        )
        continue
      }

      let split = splitPath(remainder)

      if xStatus != " " {
        let kind = GitChangeKind(statusCode: xStatus)
        staged.append(
          GitFileChange(
            path: split.newPath,
            oldPath: split.oldPath,
            kind: kind,
            location: .staged
          )
        )
      }

      if yStatus != " " {
        let kind = GitChangeKind(statusCode: yStatus)
        unstaged.append(
          GitFileChange(
            path: split.newPath,
            oldPath: split.oldPath,
            kind: kind,
            location: .unstaged
          )
        )
      }
    }

    return GitStatus(staged: staged, unstaged: unstaged, untracked: untracked)
  }

  private static func splitPath(_ pathComponent: String) -> (oldPath: String?, newPath: String) {
    let trimmed = pathComponent.trimmingCharacters(in: .whitespaces)
    if let range = trimmed.range(of: " -> ") {
      let oldPath = String(trimmed[..<range.lowerBound])
      let newPath = String(trimmed[range.upperBound...])
      return (oldPath: stripQuotes(oldPath), newPath: stripQuotes(newPath))
    }
    return (oldPath: nil, newPath: stripQuotes(trimmed))
  }

  private static func stripQuotes(_ path: String) -> String {
    guard path.count >= 2 else { return path }
    if path.hasPrefix("\"") && path.hasSuffix("\"") {
      return String(path.dropFirst().dropLast())
    }
    return path
  }
}
