import Foundation

struct PromptBatch: Sendable {
  var files: [ChangeSummary.FileSummary]
  var tokenEstimate: Int
  var lineEstimate: Int
  var fileUsages: [PromptDiagnostics.FileUsage]
  var exceedsBudget: Bool
}

struct PromptBatchPlanner {
  var tokenBudget: Int
  var headroomRatio: Double
  var minimumBatchSize: Int

  init(tokenBudget: Int = 4_096, headroomRatio: Double = 0.15, minimumBatchSize: Int = 1) {
    self.tokenBudget = max(1, tokenBudget)
    self.headroomRatio = max(0, min(headroomRatio, 0.9))
    self.minimumBatchSize = max(1, minimumBatchSize)
  }

  func planBatches(for summary: ChangeSummary) -> [PromptBatch] {
    guard !summary.files.isEmpty else { return [] }

    let targetBudget = max(1, Int(Double(tokenBudget) * (1.0 - headroomRatio)))
    let contributions = summary.files.map { file -> FileContribution in
      let lines = file.promptLines()
      let characterCount = lines.reduce(0) { partial, line in
        partial + line.count + 1
      }
      let tokenEstimate = PromptDiagnostics.tokenEstimate(forCharacterCount: characterCount)
      let fileUsage = PromptDiagnostics.FileUsage(
        path: file.path,
        kind: file.kind.description,
        location: file.location,
        lineCount: lines.count,
        tokenEstimate: tokenEstimate,
        isGenerated: file.isGenerated,
        isBinary: file.isBinary,
        snippetTruncated: file.snippetTruncated
      )
      return FileContribution(file: file, usage: fileUsage)
    }.sorted { lhs, rhs in
      if lhs.usage.tokenEstimate == rhs.usage.tokenEstimate {
        return lhs.file.path < rhs.file.path
      }
      return lhs.usage.tokenEstimate > rhs.usage.tokenEstimate
    }

    var batches: [PromptBatch] = []
    var currentFiles: [ChangeSummary.FileSummary] = []
    var currentUsages: [PromptDiagnostics.FileUsage] = []
    var currentTokenTotal = 0
    var currentLineTotal = 0

    func closeCurrentBatch(force: Bool = false) {
      guard !currentFiles.isEmpty else { return }
      let exceeds = currentTokenTotal > targetBudget
      let batch = PromptBatch(
        files: currentFiles,
        tokenEstimate: currentTokenTotal,
        lineEstimate: currentLineTotal,
        fileUsages: currentUsages,
        exceedsBudget: exceeds
      )
      batches.append(batch)
      currentFiles.removeAll(keepingCapacity: !force)
      currentUsages.removeAll(keepingCapacity: !force)
      currentTokenTotal = 0
      currentLineTotal = 0
    }

    for contribution in contributions {
      let nextTokenTotal = currentTokenTotal + contribution.usage.tokenEstimate

      if !currentFiles.isEmpty && nextTokenTotal > targetBudget {
        closeCurrentBatch()
      }

      currentFiles.append(contribution.file)
      currentUsages.append(contribution.usage)
      currentTokenTotal += contribution.usage.tokenEstimate
      currentLineTotal += contribution.usage.lineCount

      if contribution.usage.tokenEstimate > targetBudget {
        closeCurrentBatch()
      }

      if currentFiles.count >= minimumBatchSize && currentTokenTotal >= targetBudget {
        closeCurrentBatch()
      }
    }

    closeCurrentBatch(force: true)

    return batches
  }

  private struct FileContribution {
    var file: ChangeSummary.FileSummary
    var usage: PromptDiagnostics.FileUsage
  }
}
