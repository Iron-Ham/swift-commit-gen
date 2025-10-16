import Testing

@testable import SwiftCommitGen

struct CommitDraftTests {
  @Test("Parses subject and body from multi-line response")
  func parsesSubjectAndBody() {
    let response =
      "feat: add parser support\n\n- update diff parser to track renames\n- add coverage for Availability handling\n"
    let draft = CommitDraft(responseText: response)

    #expect(draft.subject == "feat: add parser support")
    #expect(
      draft.body
        == "- update diff parser to track renames\n- add coverage for Availability handling")
  }

  @Test("Handles single-line response")
  func handlesSingleLineResponse() {
    let response = "refactor: simplify git client"
    let draft = CommitDraft(responseText: response)

    #expect(draft.subject == "refactor: simplify git client")
    #expect(draft.body.isEmpty)
    #expect(draft.commitMessage == "refactor: simplify git client")
  }

  @Test("Formats full commit message")
  func formatsCommitMessage() {
    let draft = CommitDraft(subject: "feat: add api", body: "- update api\n- add docs")
    #expect(draft.commitMessage == "feat: add api\n\n- update api\n- add docs")
  }

  @Test("Normalizes labeled subject and redundant body")
  func normalizesLabeledSubject() {
    let response =
      "Subject: Fix parser bug\n\nSubject: Fix parser bug\n\nProvide additional details.\n"
    let draft = CommitDraft(responseText: response)

    #expect(draft.subject == "Fix parser bug")
    #expect(draft.body == "Provide additional details.")
  }

  @Test("Strips code fences from body")
  func stripsCodeFencesFromBody() {
    let response = "Subject: Update docs\n\n```\nRefresh README examples.\n```\n"
    let draft = CommitDraft(responseText: response)

    #expect(draft.subject == "Update docs")
    #expect(draft.body == "Refresh README examples.")
  }

  @Test("Parses JSON response with optional description")
  func parsesJSONResponse() {
    let response =
      #"{ "title": "Add retry handler", "description": "Introduce bounded retries for the model client." }"#
    let draft = CommitDraft(responseText: response)

    #expect(draft.subject == "Add retry handler")
    #expect(draft.body == "Introduce bounded retries for the model client.")
  }

  @Test("Handles JSON response without description")
  func handlesJSONWithoutDescription() {
    let response = #"{ "title": "Refactor prompt builder", "description": "" }"#
    let draft = CommitDraft(responseText: response)

    #expect(draft.subject == "Refactor prompt builder")
    #expect(draft.body.isEmpty)
  }
}
