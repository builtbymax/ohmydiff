import SwiftUI

extension View {
    /// The update bar at the bottom of the panel, while an update is found, downloads or waits for a restart.
    func updateBar(_ updater: Updater) -> some View {
        safeAreaBar(edge: .bottom) {
            if updater.phase != .idle {
                UpdateBar(updater: updater)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: updater.phase == .idle)
    }
}

private struct UpdateBar: View {
    let updater: Updater

    var body: some View {
        HStack(spacing: 10) {
            UpdateStatus(updater: updater)
            Spacer(minLength: 8)
            UpdateActions(updater: updater)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 44)
        .glassEffect(Theme.barGlass, in: .capsule)
        .shadow(color: Theme.overlayShadow, radius: 12, y: 4)
        .animation(.snappy(duration: 0.2), value: updater.phase)
    }
}

/// The update phase as an icon and a line of text, in the update bar and in Settings.
struct UpdateStatus: View {
    let updater: Updater

    var body: some View {
        HStack(spacing: 10) {
            icon
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 20)
            message
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(1)
    }

    @ViewBuilder private var icon: some View {
        switch updater.phase {
        case .available, .ready:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.logoText)
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .downloading, .extracting:
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var message: some View {
        switch updater.phase {
        case .checking:
            Text("Checking for updates…")
        case .available(let update):
            HStack(spacing: 6) {
                Text("ohmydiff \(update.version) is available").fontWeight(.medium)
                Text("You have \(Updater.currentVersion)").foregroundStyle(.secondary)
            }
        case .downloading(let update, let progress):
            HStack(spacing: 10) {
                Text("Downloading ohmydiff \(update.version)…")
                ProgressView(value: progress ?? 0)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                    .opacity(progress == nil ? 0.4 : 1)
            }
        case .extracting(let update, let progress):
            HStack(spacing: 10) {
                Text("Preparing ohmydiff \(update.version)…")
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 120)
            }
        case .ready(let update):
            Text("ohmydiff \(update.version) is ready to install").fontWeight(.medium)
        case .installing(let update):
            Text("Installing ohmydiff \(update.version). It restarts in a moment.")
        case .upToDate:
            Text("ohmydiff \(Updater.currentVersion) is the latest version.")
        case .failed(let error):
            Text("Update failed: \(error)").help(error)
        case .idle:
            EmptyView()
        }
    }

}

/// What can be done in the current update phase: install, restart, skip, cancel. In the update bar and in Settings.
struct UpdateActions: View {
    let updater: Updater

    var body: some View {
        HStack(spacing: 6) {
            switch updater.phase {
            case .available(let update):
                notesButton(update)
                if !update.isInformational {
                    Button("Skip This Version") { updater.skip() }
                        .buttonStyle(.pill(height: 32))
                }
                Button("Later") { updater.dismiss() }
                    .buttonStyle(.pill(height: 32))
                Button(update.isInformational ? "Learn More" : "Install and Restart") { updater.install() }
                    .buttonStyle(.pill(.prominent, height: 32))
            case .ready(let update):
                notesButton(update)
                Button("Later") { updater.dismiss() }
                    .buttonStyle(.pill(height: 32))
                    .glassTooltip("Installs when you quit ohmydiff", edge: .top)
                Button("Restart to Update") { updater.install() }
                    .buttonStyle(.pill(.prominent, height: 32))
            case .checking, .downloading:
                Button("Cancel") { updater.dismiss() }
                    .buttonStyle(.pill(height: 32))
            case .failed:
                Button("Try Again") { updater.checkForUpdates() }
                    .buttonStyle(.pill(height: 32))
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
                .buttonStyle(.pill(height: 32))
                .modifier(NotesCard(notes: update.notes, version: update.version))
        }
    }

    private var closeButton: some View {
        Button { updater.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
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
