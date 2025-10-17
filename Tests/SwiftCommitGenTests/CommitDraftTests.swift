import Foundation
import Testing

@testable import SwiftCommitGen

struct CommitDraftTests {
  @Test("commitMessage joins subject and body with blank line")
  func commitMessageIncludesBody() {
    let draft = CommitDraft(subject: "Add feature", body: "Explain the change")
    #expect(draft.commitMessage == "Add feature\n\nExplain the change")
  }

  @Test("commitMessage omits separator when body is empty")
  func commitMessageWithoutBody() {
    let draft = CommitDraft(subject: "Refactor module", body: nil)
    #expect(draft.commitMessage == "Refactor module")
  }

  @Test("editorRepresentation trims trailing whitespace-only body")
  func editorRepresentationTrimsWhitespaceBody() {
    let draft = CommitDraft(subject: "Fix issue", body: "   \n  ")
    #expect(draft.editorRepresentation == "Fix issue")
  }

  @Test("fromEditorContents parses subject and body segments")
  func fromEditorContentsParsesSegments() {
    let contents = "Document subject\n\nLine one\nLine two\n"
    let draft = CommitDraft.fromEditorContents(contents)

    #expect(draft.subject == "Document subject")
    #expect(draft.body == "Line one\nLine two")
  }

  @Test("fromEditorContents returns empty subject for blank input")
  func fromEditorContentsHandlesBlankInput() {
    let draft = CommitDraft.fromEditorContents("   \n\n  ")
    #expect(draft.subject.isEmpty)
    #expect(draft.body == nil)
  }
}
