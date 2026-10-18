import AppKit
import OhMyDiffCore
import SwiftUI

enum DiffLayoutMode: String {
    case unified
    case split
}

extension Notification.Name {
    /// Posted with `object: 1` (next) or `-1` (previous) to scroll the visible diff to another hunk.
    static let jumpToHunk = Notification.Name("ohmydiff.jumpToHunk")
}

/// A diff in a view-based `NSTableView`, so only visible lines are laid out.
///
/// Unified mode has one row per line with old/new gutters and scrolls sideways for long lines; split
/// mode pairs deletions with additions in two half-width columns and wraps long lines. Hunk headers span the full width. Rows can be selected (⇧/⌘-click, ⌘A) and
/// copied with ⌘C; `n` / `p` jump between hunks.
struct DiffTableView: NSViewRepresentable {
    let fileID: ChangedFile.ID
    let diff: FileDiff
    let highlights: SyntaxHighlights?
    let mode: DiffLayoutMode
    let fontSize: CGFloat
    /// Room below the last row, e.g. for a bar floating over the bottom of the diff.
    var bottomInset: CGFloat = 0
    /// The file line the selection points at (or the first change without a selection), for opening in an editor.
    var onFocusLine: (Int?) -> Void = { _ in }
    /// The hunk at the top of the visible rows, reported as the diff scrolls.
    var onVisibleHunk: (Int?) -> Void = { _ in }
    /// Actions offered in the context menu of a hunk's rows, and what runs when one is picked (with the hunk index).
    var hunkActions: [ChangeAction] = []
    var onHunkAction: (ChangeAction, Int) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = DiffNSTableView()
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = true
        tableView.floatsGroupRows = false
        tableView.backgroundColor = .textBackgroundColor
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = DiffMetrics(fontSize: fontSize).rowHeight
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.copyText = { [weak coordinator = context.coordinator] rows in coordinator?.text(for: rows) ?? "" }
        tableView.jumpToHunk = { [weak coordinator = context.coordinator] direction in coordinator?.jumpToHunk(direction) }
        tableView.rowMenu = { [weak coordinator = context.coordinator] row in coordinator?.menu(forRow: row) }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        context.coordinator.attach(tableView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onFocusLine = onFocusLine
        context.coordinator.onVisibleHunk = onVisibleHunk
        if scrollView.contentInsets.bottom != bottomInset {
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
        context.coordinator.hunkActions = hunkActions
        context.coordinator.onHunkAction = onHunkAction
        context.coordinator.show(diff, highlights: highlights, fileID: fileID, mode: mode, fontSize: fontSize)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private var fileID: ChangedFile.ID?
        private var mode: DiffLayoutMode?
        private var diff = FileDiff(oldPath: nil, newPath: nil, kind: .unknown)
        private var highlights: SyntaxHighlights?
        private var unifiedRows: [DiffLayout.UnifiedRow] = []
        private var splitRows: [DiffLayout.SplitRow] = []
        private var hunkRows: [Int] = []
        /// Split mode: each row's character count per side, to work out how many lines it wraps to.
        private var splitLengths: [(old: Int, new: Int)] = []
        /// The column width the split row heights were computed for.
        private var splitColumnWidth: CGFloat = 0
        private var formatter = DiffRowFormatter()
        private var fontSize: CGFloat?
        var onFocusLine: (Int?) -> Void = { _ in }
        var onVisibleHunk: (Int?) -> Void = { _ in }
        private var visibleHunk: Int?
        var hunkActions: [ChangeAction] = []
        var onHunkAction: (ChangeAction, Int) -> Void = { _, _ in }
        private var observers: [NSObjectProtocol] = []

        private static let oldColumn = NSUserInterfaceItemIdentifier("old")
        private static let newColumn = NSUserInterfaceItemIdentifier("new")
        private static let unifiedColumn = NSUserInterfaceItemIdentifier("unified")

        func attach(_ tableView: NSTableView, scrollView: NSScrollView) {
            self.tableView = tableView
            self.scrollView = scrollView
            scrollView.contentView.postsFrameChangedNotifications = true
            scrollView.contentView.postsBoundsChangedNotifications = true
            observers = [
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.reportVisibleHunk() } },
                NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.sizeColumns() } },
                NotificationCenter.default.addObserver(forName: .jumpToHunk, object: nil, queue: .main) { [weak self] note in
                    let direction = note.object as? Int ?? 1
                    MainActor.assumeIsolated { self?.jumpToHunk(direction) }
                },
            ]
        }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func show(_ diff: FileDiff, highlights: SyntaxHighlights?, fileID: ChangedFile.ID, mode: DiffLayoutMode, fontSize: CGFloat) {
            guard let tableView,
                  diff != self.diff || highlights != self.highlights || fileID != self.fileID || mode != self.mode
                    || fontSize != self.fontSize
            else { return }
            // Rows of the other layout do not line up with the current ones, so start over at the top.
            let isNewFile = fileID != self.fileID || mode != self.mode
            if mode != self.mode { configureColumns(for: mode) }
            self.diff = diff
            self.highlights = highlights
            self.fileID = fileID
            self.mode = mode
            self.fontSize = fontSize
            formatter = DiffRowFormatter(diff: diff, highlights: highlights, metrics: DiffMetrics(fontSize: fontSize))
            tableView.rowHeight = formatter.metrics.rowHeight

            switch mode {
            case .unified:
                unifiedRows = DiffLayout.unified(diff)
                splitRows = []
                splitLengths = []
                hunkRows = unifiedRows.indices.filter { if case .hunkHeader = unifiedRows[$0] { true } else { false } }
            case .split:
                splitRows = DiffLayout.split(diff)
                splitLengths = splitRows.map { row in
                    guard case .pair(let h, let old, let new) = row else { return (0, 0) }
                    return (old.map { formatter.splitLength(hunk: h, line: $0) } ?? 0, new.map { formatter.splitLength(hunk: h, line: $0) } ?? 0)
                }
                unifiedRows = []
                hunkRows = splitRows.indices.filter { if case .hunkHeader = splitRows[$0] { true } else { false } }
            }

            sizeColumns()
            tableView.reloadData()
            if isNewFile {
                tableView.deselectAll(nil)
                tableView.scrollRowToVisible(0)
            }
            reportFocusLine()
            reportVisibleHunk()
        }

        /// Reports the hunk of the topmost visible row when it changes.
        private func reportVisibleHunk() {
            guard let tableView, let scrollView else { return }
            let top = scrollView.contentView.bounds.minY + scrollView.contentInsets.top
            let row = max(tableView.row(at: NSPoint(x: 0, y: top + 1)), 0)
            let hunk = hunkIndex(atRow: row)
            guard hunk != visibleHunk else { return }
            visibleHunk = hunk
            onVisibleHunk(hunk)
        }

        // MARK: Hunk actions

        func menu(forRow row: Int) -> NSMenu? {
            guard !hunkActions.isEmpty, let hunk = hunkIndex(atRow: row) else { return nil }
            let menu = NSMenu()
            for action in hunkActions {
                menu.addItem(MenuHandler.item(Self.title(for: action)) { [weak self] in self?.onHunkAction(action, hunk) })
            }
            return menu
        }

        private static func title(for action: ChangeAction) -> String {
            switch action {
            case .stage: "Stage Hunk"
            case .unstage: "Unstage Hunk"
            case .commit: "Commit Hunk to Branch…"
            case .discard: "Discard Hunk…"
            }
        }

        /// The hunk a row belongs to, header included.
        private func hunkIndex(atRow row: Int) -> Int? {
            switch mode {
            case .unified:
                guard unifiedRows.indices.contains(row) else { return nil }
                switch unifiedRows[row] {
                case .hunkHeader(let h), .line(let h, _), .noNewlineAtEnd(let h, _): return h
                }
            case .split:
                guard splitRows.indices.contains(row) else { return nil }
                switch splitRows[row] {
                case .hunkHeader(let h), .pair(let h, _, _): return h
                }
            case nil:
                return nil
            }
        }

        // MARK: Editor line

        func tableViewSelectionDidChange(_ notification: Notification) {
            reportFocusLine()
        }

        private func reportFocusLine() {
            let row = tableView?.selectedRowIndexes.first
            onFocusLine(row.flatMap(fileLine(atRow:)) ?? firstChangedLine())
        }

        /// The new-file line a row shows. Deleted lines map to where they were, the next new line.
        private func fileLine(atRow row: Int) -> Int? {
            let position: (hunk: Int, line: Int)?
            switch mode {
            case .unified:
                guard unifiedRows.indices.contains(row) else { return nil }
                switch unifiedRows[row] {
                case .hunkHeader(let h): return diff.hunks[h].newStart
                case .line(let h, let l), .noNewlineAtEnd(let h, let l): position = (h, l)
                }
            case .split:
                guard splitRows.indices.contains(row) else { return nil }
                switch splitRows[row] {
                case .hunkHeader(let h): return diff.hunks[h].newStart
                case .pair(let h, let old, let new): position = (new ?? old).map { (h, $0) }
                }
            case nil:
                return nil
            }
            guard let position else { return nil }
            return Self.newLine(in: diff.hunks[position.hunk], from: position.line)
        }

        private func firstChangedLine() -> Int? {
            for hunk in diff.hunks {
                if let index = hunk.lines.firstIndex(where: { $0.kind != .context }) {
                    return Self.newLine(in: hunk, from: index)
                }
            }
            return diff.hunks.first?.newStart
        }

        private static func newLine(in hunk: Hunk, from index: Int) -> Int {
            if let number = hunk.lines[index...].lazy.compactMap(\.newLineNumber).first { return number }
            // Deletions at the end of a hunk: just after the last new line before them.
            return (hunk.lines[..<index].lazy.compactMap(\.newLineNumber).last).map { $0 + 1 } ?? max(hunk.newStart, 1)
        }

        private func configureColumns(for mode: DiffLayoutMode) {
            guard let tableView else { return }
            tableView.tableColumns.forEach(tableView.removeTableColumn)
            let identifiers = mode == .unified ? [Self.unifiedColumn] : [Self.oldColumn, Self.newColumn]
            for identifier in identifiers {
                let column = NSTableColumn(identifier: identifier)
                column.resizingMask = []
                tableView.addTableColumn(column)
            }
        }

        /// Columns are as wide as their longest line; split columns also fill at least half the pane each.
        private func sizeColumns() {
            guard let tableView, let scrollView else { return }
            let visible = scrollView.contentView.bounds.width
            switch mode {
            case .unified:
                tableView.tableColumns.first?.width = formatter.unifiedWidth(unifiedRows)
            case .split:
                // Two equal halves that always fit; long lines wrap instead of pushing the new side out of view.
                let old = floor(visible / 2)
                tableView.tableColumns.first { $0.identifier == Self.oldColumn }?.width = old
                tableView.tableColumns.first { $0.identifier == Self.newColumn }?.width = visible - old
                if old != splitColumnWidth {
                    splitColumnWidth = old
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<splitRows.count))
                }
            case nil:
                break
            }
        }

        // MARK: Hunk navigation

        func jumpToHunk(_ direction: Int) {
            guard let tableView, let scrollView, !hunkRows.isEmpty else { return }
            let topInset = scrollView.contentInsets.top
            let top = scrollView.contentView.bounds.minY + topInset
            let currentRow = max(tableView.row(at: NSPoint(x: 0, y: top + 1)), 0)

            let target = direction > 0
                ? hunkRows.first { $0 > currentRow }
                : hunkRows.last { $0 < currentRow }
            guard let target else { return }
            let y = tableView.rect(ofRow: target).minY - topInset
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // MARK: Copy

        func text(for rowIndexes: IndexSet) -> String {
            rowIndexes.compactMap { row -> String? in
                switch mode {
                case .unified:
                    guard unifiedRows.indices.contains(row) else { return nil }
                    switch unifiedRows[row] {
                    case .hunkHeader(let h): return diff.hunks[h].header
                    case .line(let h, let l): return diff.hunks[h].lines[l].text
                    case .noNewlineAtEnd: return nil
                    }
                case .split:
                    guard splitRows.indices.contains(row) else { return nil }
                    switch splitRows[row] {
                    case .hunkHeader(let h): return diff.hunks[h].header
                    // The new side is what the file contains now; deletions alone copy the old text.
                    case .pair(let h, let old, let new): return (new ?? old).map { diff.hunks[h].lines[$0].text }
                    }
                case nil:
                    return nil
                }
            }
            .joined(separator: "\n")
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            mode == .split ? splitRows.count : unifiedRows.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard mode == .split, splitLengths.indices.contains(row), splitColumnWidth > 0 else { return formatter.metrics.rowHeight }
            let lengths = splitLengths[row]
            let lines = max(formatter.wrappedLineCount(lengths.old, width: splitColumnWidth), formatter.wrappedLineCount(lengths.new, width: splitColumnWidth))
            return formatter.metrics.rowHeight + CGFloat(lines - 1) * formatter.metrics.lineHeight
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            hunkIndex(ofHeaderRow: row) != nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: DiffCellView.reuseIdentifier, owner: nil) as? DiffCellView ?? DiffCellView()
            cell.tint = nil
            cell.drawsTrailingSeparator = false
            cell.wraps = false

            if let hunk = hunkIndex(ofHeaderRow: row) {
                cell.label.attributedStringValue = formatter.hunkHeader(diff.hunks[hunk], mode: mode ?? .unified)
                return cell
            }

            switch mode {
            case .unified:
                switch unifiedRows[row] {
                case .line(let h, let l):
                    cell.label.attributedStringValue = formatter.unifiedLine(hunk: h, line: l)
                case .noNewlineAtEnd:
                    cell.label.attributedStringValue = formatter.noNewlineAtEnd(mode: .unified)
                case .hunkHeader:
                    break
                }
            case .split:
                guard case .pair(let h, let old, let new) = splitRows[row] else { break }
                let isOld = tableColumn?.identifier == Self.oldColumn
                let line = isOld ? old : new
                cell.label.attributedStringValue = line.map { formatter.splitLine(hunk: h, line: $0, side: isOld ? .old : .new) }
                    ?? NSAttributedString()
                cell.drawsTrailingSeparator = isOld
                cell.wraps = true
                if let line {
                    cell.tint = DiffRowFormatter.tint(for: diff.hunks[h].lines[line].kind)
                } else if old != new {
                    // The other side changed; this side has no counterpart line.
                    cell.tint = DiffRowFormatter.fillerTint
                }
            case nil:
                break
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: DiffRowView.reuseIdentifier, owner: nil) as? DiffRowView ?? DiffRowView()
            if hunkIndex(ofHeaderRow: row) != nil {
                rowView.tint = DiffRowFormatter.hunkTint
            } else if mode == .unified, case .line(let h, let l) = unifiedRows[row] {
                rowView.tint = DiffRowFormatter.tint(for: diff.hunks[h].lines[l].kind)
            } else {
                rowView.tint = nil
            }
            return rowView
        }

        private func hunkIndex(ofHeaderRow row: Int) -> Int? {
            switch mode {
            case .unified:
                if unifiedRows.indices.contains(row), case .hunkHeader(let h) = unifiedRows[row] { return h }
            case .split:
                if splitRows.indices.contains(row), case .hunkHeader(let h) = splitRows[row] { return h }
            case nil:
                break
            }
            return nil
        }
    }
}

// MARK: - Formatting

/// Builds the attributed strings for diff rows. Word highlights are computed once per diff.
/// Font and the sizes derived from it.
struct DiffMetrics: Equatable {
    static let defaultFontSize: CGFloat = 12

    let font: NSFont
    let rowHeight: CGFloat
    /// Height of one more wrapped line within a row.
    let lineHeight: CGFloat
    let characterWidth: CGFloat

    init(fontSize: CGFloat = defaultFontSize) {
        font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        rowHeight = lineHeight + 3
        characterWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    }
}

struct DiffRowFormatter {
    static let horizontalPadding: CGFloat = 8
    private static let tabWidth = 4

    static let hunkTint = NSColor.secondaryLabelColor.withAlphaComponent(0.07)
    static let fillerTint = NSColor.secondaryLabelColor.withAlphaComponent(0.05)
    private static let additionWordTint = NSColor.systemGreen.withAlphaComponent(0.32)
    private static let deletionWordTint = NSColor.systemRed.withAlphaComponent(0.32)

    static func tint(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: .systemGreen.withAlphaComponent(0.14)
        case .deletion: .systemRed.withAlphaComponent(0.14)
        case .context: nil
        }
    }

    enum Side { case old, new }

    private var diff = FileDiff(oldPath: nil, newPath: nil, kind: .unknown)
    private var gutterDigits = 3
    /// Changed character ranges per hunk, keyed by line index.
    private var wordHighlights: [[Int: [Range<Int>]]] = []
    private var syntax: SyntaxHighlights?

    private(set) var metrics = DiffMetrics()

    init() {}

    init(diff: FileDiff, highlights: SyntaxHighlights? = nil, metrics: DiffMetrics = DiffMetrics()) {
        self.diff = diff
        self.metrics = metrics
        self.syntax = highlights
        let largest = diff.hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 0
        gutterDigits = max(String(largest).count, 3)
        wordHighlights = diff.hunks.map(WordDiff.highlights(for:))
    }

    /// Unified: two line numbers, a space after each, then the marker and a space.
    private var unifiedPrefix: Int { gutterDigits * 2 + 2 + 2 }
    /// Split: one line number and a space, then the marker and a space.
    private var splitPrefix: Int { gutterDigits + 1 + 2 }

    // MARK: Rows

    func hunkHeader(_ hunk: Hunk, mode: DiffLayoutMode) -> NSAttributedString {
        let indent = String(repeating: " ", count: mode == .unified ? unifiedPrefix : splitPrefix)
        return NSAttributedString(string: indent + hunk.header, attributes: [.font: metrics.font, .foregroundColor: NSColor.secondaryLabelColor])
    }

    func noNewlineAtEnd(mode: DiffLayoutMode) -> NSAttributedString {
        let indent = String(repeating: " ", count: mode == .unified ? unifiedPrefix : splitPrefix)
        return NSAttributedString(
            string: indent + "No newline at end of file", attributes: [.font: metrics.font, .foregroundColor: NSColor.tertiaryLabelColor])
    }

    func unifiedLine(hunk h: Int, line l: Int) -> NSAttributedString {
        let line = diff.hunks[h].lines[l]
        let result = NSMutableAttributedString()
        append(number(line.oldLineNumber) + " " + number(line.newLineNumber) + " ", .tertiaryLabelColor, to: result)
        appendBody(line, highlights: wordHighlights[h][l], to: result)
        return result
    }

    func splitLine(hunk h: Int, line l: Int, side: Side) -> NSAttributedString {
        let line = diff.hunks[h].lines[l]
        let result = NSMutableAttributedString()
        append(number(side == .old ? line.oldLineNumber : line.newLineNumber) + " ", .tertiaryLabelColor, to: result)
        appendBody(line, highlights: wordHighlights[h][l], to: result)
        if line.noNewlineAtEnd { append("  ⏎̸", .tertiaryLabelColor, to: result) }
        // Wrapped lines continue under the code, not under the line number.
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = CGFloat(splitPrefix) * metrics.characterWidth
        paragraph.lineBreakMode = .byCharWrapping
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Characters of a split-mode line as shown: gutter, marker, expanded text and the no-newline mark.
    func splitLength(hunk h: Int, line l: Int) -> Int {
        let line = diff.hunks[h].lines[l]
        return splitPrefix + Self.expandedLength(line.text) + (line.noNewlineAtEnd ? 3 : 0)
    }

    /// How many lines `characters` take in a split column of `width`, continuation lines indented past the gutter.
    func wrappedLineCount(_ characters: Int, width: CGFloat) -> Int {
        // A little slack for the text field's own insets, so a line is never clipped.
        let available = width - Self.horizontalPadding * 2 - 6
        let first = max(Int(available / metrics.characterWidth), 1)
        guard characters > first else { return 1 }
        let following = max(first - splitPrefix, 1)
        return 1 + (characters - first + following - 1) / following
    }

    private func appendBody(_ line: DiffLine, highlights: [Range<Int>]?, to result: NSMutableAttributedString) {
        let wordTint: NSColor?
        switch line.kind {
        case .addition:
            append("+ ", .systemGreen, to: result)
            wordTint = Self.additionWordTint
        case .deletion:
            append("− ", .systemRed, to: result)
            wordTint = Self.deletionWordTint
        case .context:
            append("  ", .tertiaryLabelColor, to: result)
            wordTint = nil
        }
        appendText(line.text, highlights: highlights ?? [], tint: wordTint, syntax: syntax?.spans(for: line) ?? [], to: result)
    }

    /// Appends `text` with tabs expanded, coloring syntax spans and giving the changed word ranges a background.
    private func appendText(
        _ text: String, highlights: [Range<Int>], tint: NSColor?, syntax: [SyntaxSpan], to result: NSMutableAttributedString
    ) {
        let highlights = tint == nil ? [] : highlights
        guard !highlights.isEmpty || !syntax.isEmpty else {
            append(Self.expandingTabs(text), .labelColor, to: result)
            return
        }
        var column = 0
        var offset = 0
        var run = ""
        var runIsHighlighted = false
        var runToken: SyntaxToken?
        var nextRange = 0
        var nextSpan = 0

        func flush() {
            guard !run.isEmpty else { return }
            append(run, runToken.map(SyntaxTheme.color(for:)) ?? .labelColor, background: runIsHighlighted ? tint : nil, to: result)
            run = ""
        }

        for character in text {
            while nextRange < highlights.count, highlights[nextRange].upperBound <= offset { nextRange += 1 }
            while nextSpan < syntax.count, syntax[nextSpan].range.upperBound <= offset { nextSpan += 1 }
            let isHighlighted = nextRange < highlights.count && highlights[nextRange].contains(offset)
            let token = nextSpan < syntax.count && syntax[nextSpan].range.contains(offset) ? syntax[nextSpan].token : nil
            if isHighlighted != runIsHighlighted || token != runToken {
                flush()
                runIsHighlighted = isHighlighted
                runToken = token
            }
            if character == "\t" {
                let spaces = Self.tabWidth - column % Self.tabWidth
                run += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                run.append(character)
                column += 1
            }
            offset += 1
        }
        flush()
    }

    private func append(_ string: String, _ color: NSColor, background: NSColor? = nil, to result: NSMutableAttributedString) {
        var attributes: [NSAttributedString.Key: Any] = [.font: metrics.font, .foregroundColor: color]
        if let background { attributes[.backgroundColor] = background }
        result.append(NSAttributedString(string: string, attributes: attributes))
    }

    private func number(_ value: Int?) -> String {
        let text = value.map(String.init) ?? ""
        return String(repeating: " ", count: max(gutterDigits - text.count, 0)) + text
    }

    // MARK: Widths

    /// Width of the widest unified row, so long lines scroll horizontally instead of being cut off.
    func unifiedWidth(_ rows: [DiffLayout.UnifiedRow]) -> CGFloat {
        var longest = 0
        for row in rows {
            switch row {
            case .hunkHeader(let h): longest = max(longest, diff.hunks[h].header.count)
            case .line(let h, let l): longest = max(longest, Self.expandedLength(diff.hunks[h].lines[l].text))
            case .noNewlineAtEnd: longest = max(longest, 25)
            }
        }
        return width(characters: unifiedPrefix + longest)
    }

    func splitWidths(_ rows: [DiffLayout.SplitRow]) -> (old: CGFloat, new: CGFloat) {
        var old = 0
        var new = 0
        for case .pair(let h, let o, let n) in rows {
            if let o { old = max(old, Self.expandedLength(diff.hunks[h].lines[o].text) + 3) }
            if let n { new = max(new, Self.expandedLength(diff.hunks[h].lines[n].text) + 3) }
        }
        return (width(characters: splitPrefix + old), width(characters: splitPrefix + new))
    }

    private func width(characters: Int) -> CGFloat {
        ceil(CGFloat(characters) * metrics.characterWidth + Self.horizontalPadding * 2)
    }

    private static func expandingTabs(_ text: String) -> String {
        guard text.contains("\t") else { return text }
        var result = ""
        var column = 0
        for character in text {
            if character == "\t" {
                let spaces = tabWidth - column % tabWidth
                result += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                result.append(character)
                column += 1
            }
        }
        return result
    }

    private static func expandedLength(_ text: String) -> Int {
        guard text.contains("\t") else { return text.count }
        return expandingTabs(text).count
    }
}

// MARK: - Syntax colors

/// Token colors close to Xcode's default themes, with a light and a dark variant each.
enum SyntaxTheme {
    private static let colors: [SyntaxToken: NSColor] = [
        .keyword: dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        .string: dynamic(light: 0xC41A16, dark: 0xFC6A5D),
        .comment: dynamic(light: 0x5D6C79, dark: 0x7F8C98),
        .number: dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        .constant: dynamic(light: 0x326D74, dark: 0x67B7A4),
        .type: dynamic(light: 0x0B4F79, dark: 0x5DD8FF),
        .function: dynamic(light: 0x326D74, dark: 0x67B7A4),
        .property: dynamic(light: 0x3900A0, dark: 0xA167E6),
        .attribute: dynamic(light: 0x815F03, dark: 0xBF8555),
        .tag: dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        .escape: dynamic(light: 0x815F03, dark: 0xBF8555),
        .heading: dynamic(light: 0x0B4F79, dark: 0x5DD8FF),
        .link: dynamic(light: 0x0E0EFF, dark: 0x6699FF),
    ]

    static func color(for token: SyntaxToken) -> NSColor { colors[token] ?? .labelColor }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - AppKit views

private final class DiffNSTableView: NSTableView {
    var copyText: ((IndexSet) -> String)?
    var jumpToHunk: ((Int) -> Void)?
    var rowMenu: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? rowMenu?(row) : nil
    }

    @objc func copy(_ sender: Any?) {
        guard !selectedRowIndexes.isEmpty, let text = copyText?(selectedRowIndexes) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.charactersIgnoringModifiers, modifiers.isEmpty) {
        case ("n", true): jumpToHunk?(1)
        case ("p", true): jumpToHunk?(-1)
        default: super.keyDown(with: event)
        }
    }
}

/// A menu item that runs a closure; the item keeps its handler alive as its represented object.
private final class MenuHandler: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }

    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuHandler(handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }
}

private final class DiffRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("DiffRow")

    var tint: NSColor? {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    convenience init() {
        self.init(frame: .zero)
        identifier = Self.reuseIdentifier
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let tint else { return }
        tint.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

private final class DiffCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("DiffCell")

    let label = NSTextField(labelWithString: "")

    /// Background for split-mode cells, where each side of a row is tinted separately.
    var tint: NSColor? {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    var drawsTrailingSeparator = false {
        didSet { if drawsTrailingSeparator != oldValue { needsDisplay = true } }
    }

    /// Split cells wrap long lines to the column width; unified cells stay on one line and scroll sideways.
    var wraps = false {
        didSet {
            guard wraps != oldValue else { return }
            label.maximumNumberOfLines = wraps ? 0 : 1
            label.lineBreakMode = wraps ? .byCharWrapping : .byClipping
            trailingConstraint.isActive = wraps
            centerConstraint.isActive = !wraps
            topConstraint.isActive = wraps
        }
    }

    private var trailingConstraint: NSLayoutConstraint!
    private var centerConstraint: NSLayoutConstraint!
    private var topConstraint: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingConstraint = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DiffRowFormatter.horizontalPadding)
        centerConstraint = label.centerYAnchor.constraint(equalTo: centerYAnchor)
        topConstraint = label.topAnchor.constraint(equalTo: topAnchor, constant: 1.5)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffRowFormatter.horizontalPadding),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            centerConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if let tint {
            tint.setFill()
            // Views no longer clip to their bounds, so a split cell must not paint into the other column.
            dirtyRect.intersection(bounds).fill()
        }
        if drawsTrailingSeparator {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        }
    }
}
