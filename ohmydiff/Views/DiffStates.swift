import OhMyDiffCore
import SwiftUI

/// A generated file, e.g. a lockfile, collapsed to its size until the user asks for the diff.
struct GeneratedFileCard: View {
    let diff: FileDiff
    @Binding var collapses: Bool
    let showDiff: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                let badge = FileBadge(kind: diff.kind)
                Text(badge.letter)
                    .font(.statusLetter)
                    .foregroundStyle(badge.color)
                Text((diff.path as NSString).lastPathComponent)
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Chip("generated")
                Text(summary)
                    .font(.code(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Show diff", action: showDiff)
                    .buttonStyle(.pill(height: 26))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))

            HStack(spacing: 10) {
                Text("Collapse generated files (lockfiles, .pbxproj, dist/)")
                    .font(.control)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsSwitch(isOn: $collapses)
            }
            .padding(.horizontal, 4)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// e.g. `+1,904 −514 · 31 hunks`.
    private var summary: String {
        let hunks = diff.hunks.count == 1 ? "1 hunk" : "\(diff.hunks.count.formatted()) hunks"
        return "+\(diff.additions.formatted()) −\(diff.deletions.formatted()) · \(hunks)"
    }
}

/// Over a huge diff: how much of it is shown, and Load all.
struct LargeFileNotice: View {
    let diff: FileDiff
    let loadAll: () -> Void

    var body: some View {
        let total = DiffSettings.lineCount(diff)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                let badge = FileBadge(kind: diff.kind)
                Text(badge.letter)
                    .font(.statusLetter)
                    .foregroundStyle(badge.color)
                Text((diff.path as NSString).lastPathComponent)
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(total.formatted()) lines")
                    .font(.code(11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            GeometryReader { proxy in
                Capsule().fill(Theme.hover)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.textSecondary)
                            .frame(width: proxy.size.width * CGFloat(DiffSettings.previewLineCount) / CGFloat(max(total, 1)))
                    }
            }
            .frame(height: 4)
            HStack(spacing: 8) {
                Text("Showing lines 1–\(DiffSettings.previewLineCount.formatted()) · hunk actions return once all lines load")
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Load all", action: loadAll)
                    .buttonStyle(.pill(.ghost, height: 26))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }
}
