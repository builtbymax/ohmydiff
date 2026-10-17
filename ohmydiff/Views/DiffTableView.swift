import AppKit
import OhMyDiffCore
import SwiftUI

/// A unified diff in a view-based `NSTableView`, so only visible lines are laid out.
///
/// One row per hunk header or line, with old/new line-number gutters. Rows can be selected
/// (⇧/⌘-click, ⌘A) and copied with ⌘C.
struct DiffTableView: NSViewRepresentable {
    let fileID: ChangedFile.ID
    let diff: FileDiff

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = DiffNSTableView()
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = true
        tableView.backgroundColor = .textBackgroundColor
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = DiffRowFormatter.rowHeight
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.copyText = { [weak coordinator = context.coordinator] rows in coordinator?.text(for: rows) ?? "" }

        let column = NSTableColumn(identifier: .init("diff"))
        column.resizingMask = []
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.show(diff, fileID: fileID)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        private var fileID: ChangedFile.ID?
        private var diff: FileDiff?
        private var rows: [DiffRow] = []
        private var formatter = DiffRowFormatter(gutterDigits: 1)

        func show(_ diff: FileDiff, fileID: ChangedFile.ID) {
            guard let tableView, diff != self.diff || fileID != self.fileID else { return }
            let isNewFile = fileID != self.fileID
            self.diff = diff
            self.fileID = fileID
            rows = DiffRow.rows(for: diff)
            formatter = DiffRowFormatter(diff: diff)

            tableView.tableColumns.first?.width = formatter.contentWidth(for: rows)
            tableView.reloadData()
            if isNewFile {
                tableView.deselectAll(nil)
                tableView.scrollRowToVisible(0)
            }
        }

        func text(for rowIndexes: IndexSet) -> String {
            rowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].copyText : nil }.joined(separator: "\n")
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("DiffCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffCellView ?? DiffCellView(identifier: identifier)
            cell.label.attributedStringValue = formatter.attributedString(for: rows[row])
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("DiffRow")
            let rowView = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffRowView ?? DiffRowView()
            rowView.identifier = identifier
            rowView.tint = rows[row].tint
            return rowView
        }
    }
}

// MARK: - Rows

enum DiffRow {
    case hunkHeader(String)
    case line(DiffLine)
    case noNewlineAtEnd

    static func rows(for diff: FileDiff) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(diff.hunks.reduce(0) { $0 + $1.lines.count + 1 })
        for hunk in diff.hunks {
            rows.append(.hunkHeader(hunk.header))
            for line in hunk.lines {
                rows.append(.line(line))
                if line.noNewlineAtEnd { rows.append(.noNewlineAtEnd) }
            }
        }
        return rows
    }

    /// What ⌘C puts on the pasteboard: the line's text without its marker.
    var copyText: String? {
        switch self {
        case .hunkHeader(let header): header
        case .line(let line): line.text
        case .noNewlineAtEnd: nil
        }
    }

    var tint: NSColor? {
        switch self {
        case .hunkHeader: .systemBlue.withAlphaComponent(0.08)
        case .line(let line):
            switch line.kind {
            case .addition: .systemGreen.withAlphaComponent(0.14)
            case .deletion: .systemRed.withAlphaComponent(0.14)
            case .context: nil
            }
        case .noNewlineAtEnd: nil
        }
    }
}

// MARK: - Formatting

struct DiffRowFormatter {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let rowHeight = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 3
    private static let characterWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    private static let tabWidth = 4
    static let horizontalPadding: CGFloat = 8

    let gutterDigits: Int

    init(gutterDigits: Int) {
        self.gutterDigits = gutterDigits
    }

    init(diff: FileDiff) {
        let largest = diff.hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 0
        gutterDigits = max(String(largest).count, 3)
    }

    /// Old and new line numbers, a space each, then the marker and a space.
    private var prefixLength: Int { gutterDigits * 2 + 2 + 2 }

    func attributedString(for row: DiffRow) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func append(_ string: String, _ color: NSColor) {
            result.append(NSAttributedString(string: string, attributes: [.font: Self.font, .foregroundColor: color]))
        }

        switch row {
        case .hunkHeader(let header):
            append(String(repeating: " ", count: prefixLength) + header, .secondaryLabelColor)
        case .noNewlineAtEnd:
            append(String(repeating: " ", count: prefixLength) + "No newline at end of file", .tertiaryLabelColor)
        case .line(let line):
            append(number(line.oldLineNumber) + " " + number(line.newLineNumber) + " ", .tertiaryLabelColor)
            switch line.kind {
            case .addition: append("+ ", .systemGreen)
            case .deletion: append("− ", .systemRed)
            case .context: append("  ", .tertiaryLabelColor)
            }
            append(Self.expandingTabs(line.text), .labelColor)
        }
        return result
    }

    /// Width of the widest row, so long lines scroll horizontally instead of being cut off.
    func contentWidth(for rows: [DiffRow]) -> CGFloat {
        var longest = 0
        for row in rows {
            let length = switch row {
            case .hunkHeader(let header): header.count
            case .line(let line): Self.expandedLength(line.text)
            case .noNewlineAtEnd: 25
            }
            longest = max(longest, length)
        }
        return CGFloat(prefixLength + longest) * Self.characterWidth + Self.horizontalPadding * 2
    }

    private func number(_ value: Int?) -> String {
        let text = value.map(String.init) ?? ""
        return String(repeating: " ", count: max(gutterDigits - text.count, 0)) + text
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

// MARK: - AppKit views

private final class DiffNSTableView: NSTableView {
    var copyText: ((IndexSet) -> String)?

    @objc func copy(_ sender: Any?) {
        guard !selectedRowIndexes.isEmpty, let text = copyText?(selectedRowIndexes) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

private final class DiffRowView: NSTableRowView {
    var tint: NSColor? {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let tint else { return }
        tint.setFill()
        dirtyRect.fill()
    }
}

private final class DiffCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffRowFormatter.horizontalPadding),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
