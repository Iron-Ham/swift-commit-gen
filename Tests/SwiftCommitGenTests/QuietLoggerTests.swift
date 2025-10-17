import Foundation
import Testing

@testable import SwiftCommitGen

struct QuietLoggerTests {
  private func capture(_ body: (FileHandle) -> Void) -> String {
    let pipe = Pipe()
    body(pipe.fileHandleForWriting)
    pipe.fileHandleForWriting.closeFile()
    let data = try? pipe.fileHandleForReading.readToEnd()
    return String(data: data ?? Data(), encoding: .utf8) ?? ""
  }

  @Test("Quiet suppresses info but shows notice")
  func quietSuppressesInfoShowsNotice() {
    let output = capture { handle in
      let logger = CommitGenLogger(isVerbose: false, isQuiet: true, fileHandle: handle)
      logger.info("Routine info")
      logger.notice("Important info")
      logger.warning("Warn")
    }
    #expect(!output.contains("Routine info"))
    #expect(output.contains("Important info"))
    // In quiet non-verbose mode, labels are suppressed; ensure warning text still present.
    #expect(output.contains("Warn"))
    #expect(!output.contains("[WARNING]"))
  }

  @Test("Verbose overrides quiet")
  func verboseOverridesQuiet() {
    let output = capture { handle in
      let logger = CommitGenLogger(isVerbose: true, isQuiet: true, fileHandle: handle)
      logger.debug("Debug detail")
      logger.info("Routine info")
      logger.notice("Important info")
    }
    #expect(output.contains("[DEBUG]"))
    #expect(output.contains("[INFO]") && output.contains("Routine info"))
    #expect(output.contains("[NOTICE]") && output.contains("Important info"))
  }
}
