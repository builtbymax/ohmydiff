/// Rows of a diff laid out for display. Rows refer to hunks and lines by index, so per-line data
/// such as word highlights can be looked up without copying lines.
public enum DiffLayout {
    public enum UnifiedRow: Hashable, Sendable {
        case hunkHeader(hunk: Int)
        case line(hunk: Int, line: Int)
        /// `\ No newline at end of file` after the given line.
        case noNewlineAtEnd(hunk: Int, line: Int)
        /// The unchanged lines below the last hunk, which belongs to the given hunk.
        case trailingGap(hunk: Int)
    }

    public enum SplitRow: Hashable, Sendable {
        case hunkHeader(hunk: Int)
        /// A line on each side; `nil` leaves that side blank. Context lines appear on both sides.
        case pair(hunk: Int, old: Int?, new: Int?)
        /// The unchanged lines below the last hunk, which belongs to the given hunk.
        case trailingGap(hunk: Int)
    }

    /// `hunkHeaders: false` leaves out the header rows, e.g. for a diff expanded to the whole file;
    /// `trailingGap` adds a row for unchanged lines below the last hunk.
    public static func unified(_ diff: FileDiff, hunkHeaders: Bool = true, trailingGap: Bool = false) -> [UnifiedRow] {
        var rows: [UnifiedRow] = []
        rows.reserveCapacity(diff.hunks.reduce(0) { $0 + $1.lines.count + 1 })
        for (h, hunk) in diff.hunks.enumerated() {
            if hunkHeaders { rows.append(.hunkHeader(hunk: h)) }
            for (l, line) in hunk.lines.enumerated() {
                rows.append(.line(hunk: h, line: l))
                if line.noNewlineAtEnd { rows.append(.noNewlineAtEnd(hunk: h, line: l)) }
            }
        }
        if trailingGap, let last = diff.hunks.indices.last { rows.append(.trailingGap(hunk: last)) }
        return rows
    }

    /// Pairs each run of deletions with the additions that follow it, line by line.
    public static func split(_ diff: FileDiff, hunkHeaders: Bool = true, trailingGap: Bool = false) -> [SplitRow] {
        var rows: [SplitRow] = []
        for (h, hunk) in diff.hunks.enumerated() {
            if hunkHeaders { rows.append(.hunkHeader(hunk: h)) }
            var deletions: [Int] = []
            var additions: [Int] = []

            func flush() {
                for offset in 0..<max(deletions.count, additions.count) {
                    rows.append(.pair(
                        hunk: h,
                        old: deletions.indices.contains(offset) ? deletions[offset] : nil,
                        new: additions.indices.contains(offset) ? additions[offset] : nil))
                }
                deletions.removeAll()
                additions.removeAll()
            }

            for (l, line) in hunk.lines.enumerated() {
                switch line.kind {
                case .deletion:
                    // A deletion after additions starts a new change block.
                    if !additions.isEmpty { flush() }
                    deletions.append(l)
                case .addition:
                    additions.append(l)
                case .context:
                    flush()
                    rows.append(.pair(hunk: h, old: l, new: l))
                }
            }
            flush()
        }
        if trailingGap, let last = diff.hunks.indices.last { rows.append(.trailingGap(hunk: last)) }
        return rows
    }
}
