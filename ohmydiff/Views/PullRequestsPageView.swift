import AppKit
import OhMyDiffCore
import SwiftUI

/// The Pull requests page: what needs the user's review, their own, and what merged this week, with the
/// selected one's review panel.
struct PullRequestsPageView: View {
    let model: AppModel
    let session: ProjectSession
    @AppStorage(AppSettings.isInspectorShownKey) private var isInspectorShown = true

    private var inbox: PullRequestsModel { session.pullRequests }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isInspectorShown {
                Rectangle().fill(Theme.lineSubtle).frame(width: 1)
                Group {
                    if let item = inbox.selected {
                        ReviewPanel(model: model, session: session, item: item)
                            .id(item.number)
                    } else {
                        EmptyState("No pull request selected", systemImage: "arrow.triangle.pull")
                    }
                }
                .frame(width: 460)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .task(id: session.lastRefreshed) { await session.refreshPullRequests() }
        .alert(
            "Action Failed",
            isPresented: Binding(get: { inbox.actionError != nil }, set: { if !$0 { inbox.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inbox.actionError ?? "")
        }
    }

    @ViewBuilder private var list: some View {
        switch inbox.phase {
        case .idle:
            DelayedProgress()
        case .unavailable(let message):
            EmptyState("Pull requests need gh", systemImage: "arrow.triangle.pull", description: message)
        case .failed(let message):
            EmptyState("Could not load pull requests", systemImage: "exclamationmark.triangle", description: message) {
                Button("Try Again") { Task { await session.refreshPullRequests(force: true) } }
                    .buttonStyle(.pill())
            }
        case .ready where inbox.sections.isEmpty:
            EmptyState(
                inbox.filter == .reviewRequested ? "Nothing needs your review" : "No pull requests",
                systemImage: "checkmark.circle",
                description: inbox.filter == .reviewRequested ? "Pull requests where your review is requested show here." : nil)
        case .ready:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(inbox.sections, id: \.title) { section in
                        HStack(spacing: 8) {
                            Text(section.title).font(.sectionLabel)
                            Text("\(section.items.count)").font(.caption11)
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 12)
                        .padding(.top, 8)
                        .frame(height: 32, alignment: .leading)
                        ForEach(section.items) { item in
                            InboxRow(item: item, inbox: inbox, isSelected: inbox.selectedNumber == item.number) {
                                inbox.selectedNumber = item.number
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        }
    }
}

/// Pull requests: the filter, the repository, refresh and the review panel.
struct PullRequestsTopBar: View {
    let session: ProjectSession
    @Bindable var inbox: PullRequestsModel
    @AppStorage(AppSettings.isInspectorShownKey) private var isInspectorShown = true

    var body: some View {
        PageTitle(title: "Pull requests")
        Segmented(
            selection: $inbox.filter,
            options: [(.mine, "Mine"), (.reviewRequested, "Review requested"), (.allOpen, "All open")],
            counts: [.mine: "\(inbox.count(.mine))", .reviewRequested: "\(inbox.count(.reviewRequested))", .allOpen: "\(inbox.count(.allOpen))"])
        Spacer(minLength: 8)
        if let url = session.history.remoteURL {
            Button { NSWorkspace.shared.open(url.appending(path: "pulls")) } label: {
                Chip(url.host().map { "\($0)\(url.path())" } ?? url.absoluteString, systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
        IconButton("Refresh", systemImage: "arrow.clockwise") { Task { await session.refreshPullRequests(force: true) } }
        IconButton(isInspectorShown ? "Hide Review  ⌥⌘I" : "Show Review  ⌥⌘I", systemImage: "sidebar.right", isSelected: isInspectorShown) {
            withAnimation(.snappy(duration: 0.2)) { isInspectorShown.toggle() }
        }
    }
}

/// One pull request: state icon, title, branch and author, its checks and review, comments, people and age.
private struct InboxRow: View {
    let item: InboxPullRequest
    let inbox: PullRequestsModel
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                .font(.system(size: 13))
                .foregroundStyle(item.state == .merged ? Theme.mergedFg : item.isDraft ? Theme.textTertiary : Theme.okFg)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(inbox.needsYou(item) ? .row.weight(.medium) : .row)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("#\(item.number)")
                        .font(.detail)
                        .foregroundStyle(Theme.textTertiary)
                }
                HStack(spacing: 6) {
                    Chip(item.headRefName, systemImage: "arrow.triangle.branch")
                    Text(byline)
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.state == .open {
                ChecksChip(checks: item.checks, isCompact: true)
                reviewChip
            }
            HStack(spacing: 4) {
                Image(systemName: "bubble.left").font(.system(size: 10.5))
                Text("\(item.commentCount)").font(.caption11)
            }
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 36, alignment: .leading)
            HStack(spacing: -4) {
                ForEach(people, id: \.self) { login in
                    Avatar(login: login)
                }
            }
            Text((item.mergedAt ?? item.updatedAt).map { RelativeAge.short($0) } ?? "")
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(isSelected ? Theme.selected : isHovered ? Theme.hover : .clear, in: .rect(cornerRadius: 9))
        .contentShape(.rect(cornerRadius: 9))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Open #\(item.number) on GitHub") { NSWorkspace.shared.open(item.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
        }
    }

    /// `by lena-k · wants your review`, `by you · draft`, `by you · merged 2h ago`.
    private var byline: String {
        let author = inbox.isMine(item) ? "you" : item.author
        var parts = ["by \(author)"]
        if item.state == .merged, let mergedAt = item.mergedAt {
            parts.append("merged \(RelativeAge.short(mergedAt)) ago")
        } else if inbox.needsYou(item) {
            parts.append("wants your review")
        } else if item.isDraft {
            parts.append("draft")
        } else {
            parts.append("+\(item.additions) −\(item.deletions)")
        }
        return parts.joined(separator: " · ")
    }

    /// The author for others' pull requests, then whoever commented, at most two.
    private var people: [String] {
        let first = inbox.isMine(item) ? [] : [item.author]
        return Array((first + item.participants.filter { $0 != item.author && $0 != inbox.viewer }).prefix(2))
    }

    @ViewBuilder private var reviewChip: some View {
        if inbox.needsYou(item) {
            Chip("Review requested", systemImage: "eye", tone: .info)
        } else {
            switch item.review {
            case .approved?: Chip("Approved", systemImage: "checkmark", tone: .ok)
            case .changesRequested?: Chip("Changes requested", systemImage: "arrow.uturn.backward", tone: .warn)
            case .required?: Chip("Waiting", systemImage: "circle")
            case nil: EmptyView()
            }
        }
    }
}

/// A person's initial in a small circle.
struct Avatar: View {
    let login: String
    var isInverse = false

    var body: some View {
        Text(login.prefix(1).uppercased())
            .font(.system(size: 9.6, weight: .semibold))
            .foregroundStyle(isInverse ? Theme.textInverse : Theme.textSecondary)
            .frame(width: 20, height: 20)
            .background(isInverse ? Theme.inverse : Theme.raised, in: .circle)
            .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: isInverse ? 0 : 1.5))
            .help(login)
    }
}
