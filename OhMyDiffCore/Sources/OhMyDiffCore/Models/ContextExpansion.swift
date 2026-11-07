import Foundation

/// Unchanged lines shown in the gaps of a diff, beyond the context Git prints.
///
/// Gaps are numbered by the hunk below them: gap 0 lies above the first hunk, gap `i` between hunks `i - 1`
/// and `i`, and gap `hunks.count` below the last hunk.
public struct ContextExpansion: Sendable, Hashable {
    public struct Gap: Sendable, Hashable {
        /// Lines shown at the top of the gap, below the hunk above it.
        public var afterPrevious = 0
        /// Lines shown at the bottom of the gap, above the hunk below it.
        public var beforeNext = 0

        public init(afterPrevious: Int = 0, beforeNext: Int = 0) {
            self.afterPrevious = afterPrevious
            self.beforeNext = beforeNext
        }
    }

    public enum Direction: Sendable, Hashable {
        /// Lines below the hunk above the gap.
        case down
        /// Lines above the hunk below the gap.
        case up
        /// The whole gap.
        case all
    }

    public var gaps: [Int: Gap] = [:]

    public init(gaps: [Int: Gap] = [:]) {
        self.gaps = gaps
    }

    public var isEmpty: Bool { gaps.values.allSatisfy { $0.afterPrevious == 0 && $0.beforeNext == 0 } }

    /// Shows `count` more lines of a gap, from the side `direction` names. Lines past the gap's end are
    /// ignored when the expansion is applied, so `.all` needs no size.
    public mutating func expand(gap: Int, _ direction: Direction, by count: Int) {
        var expanded = gaps[gap] ?? Gap()
        switch direction {
        case .down: expanded.afterPrevious = saturatingSum(expanded.afterPrevious, count)
        case .up: expanded.beforeNext = saturatingSum(expanded.beforeNext, count)
        case .all: expanded.beforeNext = .max
        }
        gaps[gap] = expanded
    }
}

extension FileDiff {
    /// Unchanged lines left out above each hunk: from the top of the file for the first one, else since the
    /// hunk before it.
    public var unchangedLinesAbove: [Int] {
        var previousEnd = 0
        return hunks.map { hunk in
            // A hunk with no lines on the old side starts after its start line rather than at it.
            let before = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
            defer { previousEnd = before + hunk.oldCount }
            return max(before - previousEnd, 0)
        }
    }

    /// Unchanged lines below the last hunk, given this diff expanded to the whole file; also for a diff with
    /// lines revealed from it.
    public func unchangedLinesBelow(in whole: FileDiff) -> Int? {
        guard let last = hunks.last, let wholeLast = whole.hunks.last, whole.hunks.count == hunks.count else { return nil }
        // Unchanged lines have numbers on both sides; count on the old one, which every modified file has.
        func end(_ hunk: Hunk) -> Int {
            hunk.lines.last { $0.oldLineNumber != nil }?.oldLineNumber ?? (hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1)
        }
        let count = end(wholeLast) - end(last)
        return count >= 0 ? count : nil
    }

    /// The diff with the unchanged lines `expansion` asks for filled in, read from `whole`, this diff
    /// expanded to the whole file (see `expandedToWholeFile`).
    ///
    /// Hunks keep their order and count, so hunk indices still match this diff: lines below a hunk join it,
    /// and lines above a hunk join the one below. Returns `nil` when `whole` is not this diff expanded.
    public func revealing(_ expansion: ContextExpansion, from whole: FileDiff) -> FileDiff? {
        guard whole.hunks.count == hunks.count, let last = hunks.indices.last else { return nil }
        let above = unchangedLinesAbove
        var result = self
        for index in hunks.indices {
            let wholeLines = whole.hunks[index].lines
            guard wholeLines.count >= above[index] + hunks[index].lines.count else { return nil }
            let gapLines = wholeLines.prefix(above[index])
            let gap = expansion.gaps[index] ?? .init()
            if index == 0 {
                // Nothing lies above the first gap, so it only grows upwards from the first hunk.
                result.hunks[index].prepend(gapLines.suffix(min(gap.total, above[index])))
            } else {
                let before = min(gap.beforeNext, above[index])
                result.hunks[index - 1].append(gapLines.prefix(min(gap.afterPrevious, above[index] - before)))
                result.hunks[index].prepend(gapLines.suffix(before))
            }
        }
        // Nothing lies below the last gap, so it only grows downwards from the last hunk.
        let tail = whole.hunks[last].lines.dropFirst(above[last] + hunks[last].lines.count)
        let gap = expansion.gaps[hunks.count] ?? .init()
        result.hunks[last].append(tail.prefix(min(gap.total, tail.count)))
        return result
    }
}

private extension ContextExpansion.Gap {
    /// Lines shown from either side, for a gap with a hunk on one side only.
    var total: Int { saturatingSum(afterPrevious, beforeNext) }
}

/// `.all` stores `Int.max`, so sums of line counts stop there instead of overflowing.
private func saturatingSum(_ a: Int, _ b: Int) -> Int {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? .max : sum
}

private extension Hunk {
    mutating func prepend(_ unchanged: ArraySlice<DiffLine>) {
        guard let first = unchanged.first else { return }
        lines.insert(contentsOf: unchanged, at: 0)
        if let number = first.oldLineNumber { oldStart = number }
        if let number = first.newLineNumber { newStart = number }
        oldCount += unchanged.count
        newCount += unchanged.count
    }

    mutating func append(_ unchanged: ArraySlice<DiffLine>) {
        guard let first = unchanged.first else { return }
        // A side the hunk had no lines on starts at the first unchanged line now.
        if oldCount == 0, let number = first.oldLineNumber { oldStart = number }
        if newCount == 0, let number = first.newLineNumber { newStart = number }
        lines += unchanged
        oldCount += unchanged.count
        newCount += unchanged.count
    }
}
