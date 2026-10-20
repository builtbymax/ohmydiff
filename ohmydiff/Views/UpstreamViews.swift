import AppKit
import OhMyDiffCore
import SwiftUI

/// `origin/main · 10 min ago` in the toolbar: fetches on click, and offers the update once the remote
/// has commits the workspace lacks.
struct UpstreamControls: View {
    @Bindable var model: AppModel
    let session: ProjectSession
    @State private var isPillHovered = false

    var body: some View {
        // In a narrow window the pill drops the target and fetch time, and the button says only "Update".
        ViewThatFits(in: .horizontal) {
            controls(isCompact: false)
            controls(isCompact: true)
        }
        .animation(.snappy(duration: 0.2), value: session.upstream?.hasUpdates)
    }

    private func controls(isCompact: Bool) -> some View {
        HStack(spacing: 10) {
            if session.upstream != nil || session.isFetching || session.fetchError != nil {
                fetchPill(isCompact: isCompact)
            }
            if let upstream = session.upstream, upstream.hasUpdates {
                Button { model.isUpstreamUpdatePresented = true } label: {
                    Text(isCompact ? "Update" : Self.updateTitle(upstream))
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(Theme.logo, in: .capsule)
                .shadow(color: Theme.overlayShadow, radius: 6, y: 2)
                .focusEffectDisabled()
                .glassTooltip("Review and Update…")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .fixedSize()
    }

    private func fetchPill(isCompact: Bool) -> some View {
        Button { Task { await session.fetch() } } label: {
            HStack(spacing: 7) {
                if !isCompact {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    Text(session.upstream?.target ?? "Remote")
                        .foregroundStyle(.secondary)
                    Divider().frame(height: 14)
                }
                if session.isFetching {
                    ProgressView().controlSize(.mini)
                    if !isCompact { Text("Fetching…") }
                } else if session.fetchError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    if !isCompact { Text("Fetch failed") }
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    if !isCompact, let lastFetched = session.lastFetched {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(Self.fetchedTitle(lastFetched))
                        }
                    }
                }
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background(Theme.glassSelection.opacity(isPillHovered ? 1 : 0), in: .capsule)
        .onHover { isPillHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isPillHovered)
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(session.isFetching || session.isUpdatingFromUpstream)
        .focusEffectDisabled()
        .glassTooltip(session.fetchError.map { "Fetch failed: \($0)" } ?? "Fetch from \(session.upstream?.target ?? "the remote")")
    }

    static func fetchedTitle(_ date: Date) -> String {
        Date.now.timeIntervalSince(date) < 60 ? "Just now" : date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// `33 upstream commits`, or what is left to tidy up when the remote has nothing new.
    static func updateTitle(_ upstream: UpstreamStatus) -> String {
        switch upstream.incoming.count {
        case 0: upstream.branches.count == 1 ? "1 branch to update" : "\(upstream.branches.count) branches to update"
        case 1: "1 upstream commit"
        case let count: "\(count) upstream commits"
        }
    }
}

/// The incoming commits and what updating does to each branch, before updating.
struct UpstreamUpdateSheet: View {
    let session: ProjectSession

    @Environment(\.dismiss) private var dismiss
    @State private var result: UpstreamUpdateResult?
    @State private var error: String?

    private var isGitButler: Bool { session.project.kind == .gitButler }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let upstream = session.upstream {
                header(upstream)
                if let result {
                    ResultSummary(result: result, isGitButler: isGitButler)
                } else {
                    if !upstream.incoming.isEmpty { incoming(upstream) }
                    if !upstream.branches.isEmpty { branches(upstream) }
                    if upstream.hasWorktreeConflicts {
                        notice("Uncommitted changes conflict with the incoming commits. Commit or discard them first.", color: .orange)
                    }
                }
            } else {
                Text("Nothing to update.").foregroundStyle(.secondary)
            }
            footer
        }
        .padding(20)
        .frame(width: 520)
    }

    private func header(_ upstream: UpstreamStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(Theme.logo, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(result == nil ? "Update from \(upstream.target)" : "Workspace Updated")
                    .font(.headline)
                Text(isGitButler ? "Rebases the applied branches with `but pull`" : "Brings your local branches up to date with their upstreams")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func incoming(_ upstream: UpstreamStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionTitle("Incoming Changes")
                CountBadge(count: upstream.incoming.count)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(upstream.incoming) { commit in
                        IncomingCommitRow(commit: commit, url: session.history.remoteURL?.appending(path: "commit").appending(path: commit.sha))
                        if commit.id != upstream.incoming.last?.id { Divider().padding(.leading, 34) }
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .fieldBackground(isFocused: false)
        }
    }

    private func branches(_ upstream: UpstreamStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("To Be Updated")
            VStack(spacing: 0) {
                ForEach(upstream.branches) { branch in
                    BranchUpdateRow(update: branch, isGitButler: isGitButler)
                    if branch.id != upstream.branches.last?.id { Divider().padding(.leading, 34) }
                }
            }
            .padding(4)
            .fieldBackground(isFocused: false)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.deletion)
                    .textSelection(.enabled)
                    .lineLimit(3)
            } else if isGitButler, result == nil {
                HStack(spacing: 5) {
                    Text("Revert with `but undo`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if result != nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.pill(.prominent, height: 32))
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.pill(height: 32))
                Button { update() } label: {
                    if session.isUpdatingFromUpstream {
                        ProgressView().controlSize(.small).tint(.black)
                    } else {
                        Text(isGitButler ? "Update Workspace" : "Update Branches")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.pill(.prominent, height: 32))
                .disabled(session.isUpdatingFromUpstream || session.upstream?.hasUpdates != true)
            }
        }
        .focusEffectDisabled()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func notice(_ text: String, color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func update() {
        error = nil
        Task {
            do {
                result = try await session.updateFromUpstream()
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}

private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: .capsule)
    }
}

private struct IncomingCommitRow: View {
    let commit: CommitInfo
    let url: URL?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "smallcircle.filled.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.summary)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    Text(commit.shortSHA).monospaced()
                    if !commit.authorName.isEmpty { Text("· \(commit.authorName)") }
                    if let date = commit.date { Text("· \(date, format: .relative(presentation: .named))") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let url {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.hoverCapsule())
                .focusEffectDisabled()
                .glassTooltip("Open on \(RemoteHost(url).name)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
    }
}

private struct BranchUpdateRow: View {
    let update: BranchUpdate
    let isGitButler: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(update.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let badge {
                Text(badge.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(badge.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(badge.color.opacity(Theme.kindTintOpacity), in: .capsule)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Label(outcome.text, systemImage: outcome.systemImage)
                .font(.caption)
                .foregroundStyle(outcome.color)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 34)
    }

    private var badge: (title: String, color: Color)? {
        switch update.action {
        case .integrated: ("Integrated", .purple)
        case .conflicts: ("Conflicts", .red)
        case .diverged: ("Diverged", .orange)
        case .rebase, .fastForward: nil
        }
    }

    private var outcome: (text: String, systemImage: String, color: Color) {
        switch update.action {
        case .rebase: ("Rebases onto the new base", "arrow.up.circle", .secondary)
        case .fastForward: ("Moves forward", "arrow.up.circle", .secondary)
        case .integrated: (isGitButler ? "Part of the new base" : "Removed, part of the new base", "checkmark", .secondary)
        case .conflicts: (isGitButler ? "Commits marked conflicted" : "Left as is", "exclamationmark.triangle", .red)
        case .diverged: ("Left as is", "minus.circle", .secondary)
        }
    }
}

private struct ResultSummary: View {
    let result: UpstreamUpdateResult
    let isGitButler: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            line("Updated", result.updated, systemImage: "checkmark.circle.fill", color: Theme.changeAdded)
            line("Integrated and removed", result.integrated, systemImage: "checkmark.seal.fill", color: .purple)
            line("Conflicted", result.conflicted, systemImage: "exclamationmark.triangle.fill", color: .red)
            if !result.conflicted.isEmpty {
                Text(isGitButler
                    ? "Resolve the conflicted commits with `but resolve`, or revert the update with `but undo`."
                    : "These branches were left as they were. Rebase them onto their upstream in a terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if result.updated.isEmpty, result.integrated.isEmpty, result.conflicted.isEmpty {
                Text("Everything is up to date.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func line(_ title: String, _ names: [String], systemImage: String, color: Color) -> some View {
        if !names.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(names.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
