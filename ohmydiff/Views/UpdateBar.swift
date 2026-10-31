import SwiftUI

extension View {
    /// The quiet strip at the bottom of the panel, while an update is found, downloads or waits for a restart.
    func updateBar(_ updater: Updater) -> some View {
        safeAreaBar(edge: .bottom) {
            if updater.phase != .idle {
                UpdateBar(updater: updater)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.popoverAnimation, value: updater.phase == .idle)
    }
}

private struct UpdateBar: View {
    let updater: Updater

    var body: some View {
        HStack(spacing: 10) {
            UpdateStatus(updater: updater, isCompact: true)
            Spacer(minLength: 8)
            UpdateActions(updater: updater, height: 26)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.lineSubtle).frame(height: 1) }
        .animation(Theme.popoverAnimation, value: updater.phase)
    }
}

/// The update phase as an icon and a line of text, in the update bar and in Settings.
struct UpdateStatus: View {
    let updater: Updater
    /// The bar's single line: the version, then the notes' first line in tertiary text.
    var isCompact = false

    var body: some View {
        HStack(spacing: 10) {
            icon
                .font(.system(size: isCompact ? 12 : 15, weight: .medium))
                .frame(width: isCompact ? 14 : 20)
            message
                .font(.control)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(1)
    }

    @ViewBuilder private var icon: some View {
        switch updater.phase {
        case .available, .ready:
            Image(systemName: "arrow.trianglehead.2.clockwise").foregroundStyle(Theme.infoFg)
        case .checking, .installing:
            ProgressView().controlSize(.mini)
        case .downloading, .extracting:
            Image(systemName: "arrow.down.circle").foregroundStyle(Theme.textTertiary)
        case .upToDate:
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.okFg)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warnFg)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var message: some View {
        switch updater.phase {
        case .checking:
            Text("Checking for updates…").foregroundStyle(Theme.textSecondary)
        case .available(let update):
            headline("ohmydiff \(update.version) is available", update: update, fallback: "You have \(Updater.currentVersion)")
        case .downloading(let update, let progress):
            HStack(spacing: 10) {
                Text("Downloading ohmydiff \(update.version)…").foregroundStyle(Theme.textSecondary)
                ProgressBar(value: progress ?? 0)
                    .opacity(progress == nil ? 0.4 : 1)
            }
        case .extracting(let update, let progress):
            HStack(spacing: 10) {
                Text("Preparing ohmydiff \(update.version)…").foregroundStyle(Theme.textSecondary)
                ProgressBar(value: progress)
            }
        case .ready(let update):
            headline("ohmydiff \(update.version) is ready", update: update, fallback: nil)
        case .installing(let update):
            Text("Installing ohmydiff \(update.version). It restarts in a moment.").foregroundStyle(Theme.textSecondary)
        case .upToDate:
            Text("ohmydiff \(Updater.currentVersion) is the latest version.").foregroundStyle(Theme.textSecondary)
        case .failed(let error):
            Text("Update failed: \(error)").foregroundStyle(Theme.textSecondary).help(error)
        case .idle:
            EmptyView()
        }
    }

    /// "ohmydiff 1.4.0 is ready · layout per project, faster large diffs".
    private func headline(_ title: String, update: Updater.Update, fallback: String?) -> some View {
        HStack(spacing: 10) {
            Text(title).fontWeight(.medium).foregroundStyle(Theme.textPrimary)
            if let summary = Self.summary(of: update) ?? fallback {
                Text("· \(summary)")
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// The first line of the release notes, without list markers.
    static func summary(of update: Updater.Update) -> String? {
        guard let notes = update.notes else { return nil }
        let line = String(notes.characters).split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ").union(.whitespaces)) }
            .first { !$0.isEmpty }
        return line.map { $0.prefix(1).lowercased() + $0.dropFirst() }
    }
}

/// A thin 4pt progress track, as in the large-file state.
private struct ProgressBar: View {
    let value: Double

    var body: some View {
        Capsule().fill(Theme.hover)
            .frame(width: 120, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.textSecondary).frame(width: 120 * min(max(value, 0), 1), height: 4)
            }
    }
}

/// What can be done in the current update phase: install, restart, skip, cancel. In the update bar and in Settings.
struct UpdateActions: View {
    let updater: Updater
    var height: CGFloat = 32

    var body: some View {
        HStack(spacing: 6) {
            switch updater.phase {
            case .available(let update):
                notesButton(update)
                if !update.isInformational {
                    Button("Skip This Version") { updater.skip() }
                        .buttonStyle(.pill(height: height))
                }
                Button("Later") { updater.dismiss() }
                    .buttonStyle(.pill(.ghost, height: height))
                Button(update.isInformational ? "Learn More" : "Install and Restart") { updater.install() }
                    .buttonStyle(.pill(.prominent, height: height))
            case .ready(let update):
                notesButton(update)
                Button("Later") { updater.dismiss() }
                    .buttonStyle(.pill(.ghost, height: height))
                    .glassTooltip("Installs when you quit ohmydiff", edge: .top)
                Button("Restart") { updater.install() }
                    .buttonStyle(.pill(.prominent, height: height))
            case .checking, .downloading:
                Button("Cancel") { updater.dismiss() }
                    .buttonStyle(.pill(height: height))
            case .failed:
                Button("Try Again") { updater.checkForUpdates() }
                    .buttonStyle(.pill(height: height))
                closeButton
            case .upToDate:
                closeButton
            case .extracting, .installing, .idle:
                EmptyView()
            }
        }
        .focusEffectDisabled()
    }

    @ViewBuilder private func notesButton(_ update: Updater.Update) -> some View {
        if let url = update.notesURL {
            Button("What’s New") { NSWorkspace.shared.open(url) }
                .buttonStyle(.pill(height: height))
                .modifier(NotesCard(notes: update.notes, version: update.version))
        }
    }

    private var closeButton: some View {
        Button { updater.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: height, height: height)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassTooltip("Dismiss", edge: .top)
    }
}

/// The embedded release notes in a hover card above What’s New.
private struct NotesCard: ViewModifier {
    let notes: AttributedString?
    let version: String

    func body(content: Content) -> some View {
        if let notes {
            content.hoverCard(edge: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What’s new in \(version)")
                        .font(.caption.weight(.semibold))
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(20)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            content
        }
    }
}
