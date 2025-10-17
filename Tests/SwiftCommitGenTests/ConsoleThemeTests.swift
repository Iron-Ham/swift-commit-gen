import Foundation
import Testing

@testable import SwiftCommitGen

struct ConsoleThemeTests {
  @Test("Style.wrap emits ANSI codes when enabled and codes exist")
  func styleWrapProducesCodes() {
    let style = ConsoleTheme.Style(codes: [31, 1])
    let wrapped = style.wrap("error", isEnabled: true)

    #expect(wrapped.hasPrefix("\u{001B}[31;1m"))
    #expect(wrapped.hasSuffix("\u{001B}[0m"))
  }

  @Test("Style.wrap returns original text when disabled")
  func styleWrapDisabledReturnsOriginal() {
    let style = ConsoleTheme.Style(codes: [32])
    let wrapped = style.wrap("message", isEnabled: false)
    #expect(wrapped == "message")
  }

  @Test("prefix is empty when codes are empty")
  func prefixIsEmptyWithoutCodes() {
    let style = ConsoleTheme.Style(codes: [])
    #expect(style.prefix(isEnabled: true).isEmpty)
  }
}
