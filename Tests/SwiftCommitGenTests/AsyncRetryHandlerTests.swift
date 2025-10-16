import Foundation
import Testing

@testable import SwiftCommitGen

struct AsyncRetryHandlerTests {
  actor AttemptCounter {
    private var value = 0

    func increment() -> Int {
      value += 1
      return value
    }

    func current() -> Int {
      value
    }
  }

  enum TestError: Error {
    case transient
  }

  @Test("Succeeds without retry")
  func succeedsWithoutRetry() async throws {
    let handler = AsyncRetryHandler(maxAttempts: 3, requestTimeout: 0, retryDelay: 0)
    let attempts = AttemptCounter()

    let value = try await handler.execute {
      await attempts.increment()
    }

    #expect(value == 1)
    #expect(await attempts.current() == 1)
  }

  @Test("Retries transient failures")
  func retriesTransientFailures() async throws {
    let handler = AsyncRetryHandler(maxAttempts: 3, requestTimeout: 0, retryDelay: 0)
    let attempts = AttemptCounter()

    let value = try await handler.execute {
      let current = await attempts.increment()
      if current < 2 {
        throw TestError.transient
      }
      return current
    }

    #expect(value == 2)
    #expect(await attempts.current() == 2)
  }

  @Test("Fails after exhausting attempts")
  func failsAfterExhaustingAttempts() async {
    let handler = AsyncRetryHandler(maxAttempts: 2, requestTimeout: 0, retryDelay: 0)
    let attempts = AttemptCounter()

    do {
      _ = try await handler.execute {
        _ = await attempts.increment()
        throw TestError.transient
      }
      Issue.record("Expected execution to throw")
    } catch let error as CommitGenError {
      switch error {
      case .modelGenerationFailed(let message):
        #expect(message.contains("Failed to generate a commit draft after"))
      default:
        Issue.record("Unexpected CommitGenError: \(error)")
      }
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(await attempts.current() == 2)
  }

  @Test("Times out long-running operation")
  func timesOutLongRunningOperation() async {
    let handler = AsyncRetryHandler(maxAttempts: 1, requestTimeout: 0.05, retryDelay: 0)

    do {
      _ = try await handler.execute {
        try await Task.sleep(nanoseconds: 200_000_000)
        return true
      }
      Issue.record("Expected timeout error")
    } catch let error as CommitGenError {
      switch error {
      case .modelTimedOut(let timeout):
        #expect(timeout >= 0.05)
      default:
        Issue.record("Unexpected CommitGenError: \(error)")
      }
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
