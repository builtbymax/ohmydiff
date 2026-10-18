import Foundation

extension FileDiff {
    /// The diff with every unchanged line of the file filled in, so it reads as the whole file.
    ///
    /// Hunks keep their order and count, so hunk indices still match this diff: each hunk takes the
    /// unchanged lines before it, and the last one also those after it. `old` and `new` are the file's
    /// contents on each side; either may be `nil` when the file does not exist there. Returns `nil` when
    /// the contents do not line up with the diff, e.g. because the file changed after it was diffed.
    public func expandedToWholeFile(old: Data?, new: Data?) -> FileDiff? {
        guard !isBinary, !hunks.isEmpty else { return nil }
        let oldLines = old?.lines()
        let newLines = new?.lines()
        // Unchanged lines are the same on both sides; read them from whichever side exists.
        guard let source = newLines ?? oldLines else { return nil }
        let sourceIsNew = newLines != nil

        var result = self
        // The first line on each side not shown yet.
        var nextOld = 1
        var nextNew = 1

        func unchangedLines(_ count: Int) -> [DiffLine]? {
            guard count >= 0 else { return nil }
            var lines: [DiffLine] = []
            lines.reserveCapacity(count)
            for offset in 0..<count {
                let index = (sourceIsNew ? nextNew : nextOld) + offset - 1
                guard source.indices.contains(index) else { return nil }
                lines.append(DiffLine(
                    kind: .context, text: String(decoding: source[index], as: UTF8.self),
                    oldLineNumber: nextOld + offset, newLineNumber: nextNew + offset))
            }
            return lines
        }

        for index in result.hunks.indices {
            let hunk = result.hunks[index]
            guard Self.matches(hunk, old: oldLines, new: newLines) else { return nil }
            // A hunk with no lines on a side starts after its start line rather than at it.
            let oldBefore = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
            let newBefore = hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1
            let gap = newBefore - (nextNew - 1)
            guard oldBefore - (nextOld - 1) == gap, let gapLines = unchangedLines(gap) else { return nil }
            if gap > 0 {
                result.hunks[index] = Hunk(
                    oldStart: nextOld, oldCount: hunk.oldCount + gap, newStart: nextNew, newCount: hunk.newCount + gap,
                    section: hunk.section, lines: gapLines + hunk.lines)
            }
            nextOld = oldBefore + hunk.oldCount + 1
            nextNew = newBefore + hunk.newCount + 1
        }

        let remaining = source.count - (sourceIsNew ? nextNew : nextOld) + 1
        if let oldLines, let newLines, oldLines.count - nextOld != newLines.count - nextNew { return nil }
        guard var tail = unchangedLines(remaining), let last = result.hunks.indices.last else { return nil }
        if !tail.isEmpty {
            if let data = new ?? old, data.last != 0x0A { tail[tail.count - 1].noNewlineAtEnd = true }
            result.hunks[last].lines += tail
            result.hunks[last].oldCount += tail.count
            result.hunks[last].newCount += tail.count
        }
        return result
    }

    /// Whether the lines a hunk shows are the lines the file has at those numbers.
    private static func matches(_ hunk: Hunk, old: [Data]?, new: [Data]?) -> Bool {
        hunk.lines.allSatisfy { line in
            if line.kind != .deletion, let new, let number = line.newLineNumber {
                return new.indices.contains(number - 1) && String(decoding: new[number - 1], as: UTF8.self) == line.text
            }
            if line.kind != .addition, let old, let number = line.oldLineNumber {
                return old.indices.contains(number - 1) && String(decoding: old[number - 1], as: UTF8.self) == line.text
            }
            return true
        }
    }
}
