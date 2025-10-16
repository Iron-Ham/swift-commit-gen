import Foundation

enum GitChangeScope {
  case staged
  case unstaged
  case all
}

enum GitChangeLocation {
  case staged
  case unstaged
  case untracked
}

enum GitChangeKind: String {
  case added = "A"
  case modified = "M"
  case deleted = "D"
  case renamed = "R"
  case copied = "C"
  case typeChange = "T"
  case unmerged = "U"
  case untracked = "?"
  case unknown = "-" // default fallback

  var description: String {
    switch self {
    case .added:
      return "added"
    case .modified:
      return "modified"
    case .deleted:
      return "deleted"
    case .renamed:
      return "renamed"
    case .copied:
      return "copied"
    case .typeChange:
      return "type change"
    case .unmerged:
      return "unmerged"
    case .untracked:
      return "untracked"
    case .unknown:
      return "unknown"
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

struct GitFileChange {
  var path: String
  var oldPath: String?
  var kind: GitChangeKind
  var location: GitChangeLocation

  var displayPath: String {
    if let oldPath {
      return "\(oldPath) -> \(path)"
    }
    return path
  }

  var summary: String {
    "[\(kind.rawValue)] \(displayPath)"
  }
}

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
      return staged
    case .unstaged:
      return unstaged
    case .all:
      return staged + unstaged + untracked
    }
  }
}

protocol GitClient {
  func repositoryRoot() async throws -> URL
  func status() async throws -> GitStatus
  func diffStaged() async throws -> String
  func diffUnstaged() async throws -> String
  func listChangedFiles(scope: GitChangeScope) async throws -> [GitFileChange]
}

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

  func diffStaged() async throws -> String {
    _ = try await repositoryRoot()
  return try runGit(["diff", "--cached", "--no-color"])
  }

  func diffUnstaged() async throws -> String {
    _ = try await repositoryRoot()
  return try runGit(["diff", "--no-color"])
  }

  func listChangedFiles(scope: GitChangeScope) async throws -> [GitFileChange] {
    let status = try await status()
    return status.changes(for: scope)
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

    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

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
