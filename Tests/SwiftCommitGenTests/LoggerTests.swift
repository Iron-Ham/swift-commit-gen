import Foundation
import Testing

@testable import SwiftCommitGen

#if canImport(Darwin)
  import Darwin
#endif

struct LoggerTests {
  private func captureLogger(_ body: (FileHandle) -> Void) -> String {
    let pipe = Pipe()
    body(pipe.fileHandleForWriting)
    pipe.fileHandleForWriting.closeFile()
    let data = try? pipe.fileHandleForReading.readToEnd()
    return String(data: data ?? Data(), encoding: .utf8) ?? ""
  }

  @Test("Debug messages suppressed when not verbose")
  func debugSuppressedWhenNotVerbose() {
    let output = captureLogger { handle in
      let logger = CommitGenLogger(isVerbose: false, fileHandle: handle)
      logger.debug("Hidden debug message")
      logger.info("Visible info message")
    }
    // Non-verbose: info message present without label; debug suppressed entirely.
    #expect(output.contains("Visible info message"))
    #expect(!output.contains("[INFO]"))
    #expect(!output.contains("Hidden debug message"))
    #expect(!output.contains("[DEBUG]"))
  }

  @Test("Debug messages emitted when verbose")
  func debugEmittedWhenVerbose() {
    let output = captureLogger { handle in
      let logger = CommitGenLogger(isVerbose: true, fileHandle: handle)
      logger.debug("Visible debug message")
      logger.info("Also visible info message")
    }
    // Verbose: labels shown for info and debug.
    #expect(output.contains("[INFO]"))
    #expect(output.contains("[DEBUG]"))
    #expect(output.contains("Also visible info message"))
    #expect(output.contains("Visible debug message"))
  }

  @Test("Info label appears only in verbose mode")
  func infoLabelConditional() {
    let nonVerbose = captureLogger { handle in
      let logger = CommitGenLogger(isVerbose: false, fileHandle: handle)
      logger.info("Ping")
    }
    let verbose = captureLogger { handle in
      let logger = CommitGenLogger(isVerbose: true, fileHandle: handle)
      logger.info("Ping")
    }
    #expect(nonVerbose.contains("Ping"))
    #expect(!nonVerbose.contains("[INFO]"))
    #expect(verbose.contains("[INFO]") && verbose.contains("Ping"))
  }
}
