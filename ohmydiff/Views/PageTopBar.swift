import AppKit
import OhMyDiffCore
import SwiftUI

/// The 46 pt bar at the top of the content panel. Changes shows the open file and the branch's remote
/// actions; the other pages show their title and filters.
struct PageTopBar: View {
    let model: AppModel
    let mode: WorkspaceMode

    var body: some View {
        HStack(spacing: 2) {
            if let session = model.selectedSession {
                switch mode {
                case .changes:
                    ChangesTopBar(model: model, session: session)
                case .pullRequests:
                    PullRequestsTopBar(session: session, inbox: session.pullRequests)
                case .branches:
                    BranchesTopBar(model: model, session: session, history: session.history)
                case .history:
                    HistoryTopBar(session: session, log: session.log)
                }
            } else {
                dragArea
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 46)
        .background(dragArea)
    }

    /// The bar's empty stretch moves the window, like a title bar.
    private var dragArea: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(WindowDragGesture())
    }
}

/// Changes: the selected file, then fetching, pushing and the pull request of its branch.
private struct ChangesTopBar: View {
    let model: AppModel
    let session: ProjectSession

    var body: some View {
        FileTabs(session: session)
        Spacer(minLength: 8)
        if session.project.kind != .gitButler, let branch = session.currentBranch {
            Chip(branch, systemImage: "arrow.triangle.branch")
                .padding(.trailing, 6)
        }
        if session.phase == .ready {
            FetchButton(model: model, session: session, isLabeled: session.project.kind != .gitButler)
            if let branch {
                PushButton(history: session.history, branch: branch)
                    .padding(.leading, 4)
                if let pullRequest = session.history.pullRequest(of: branch) {
                    PullRequestButton(history: session.history, pullRequest: pullRequest)
                        .padding(.leading, 6)
                }
            }
        }
    }

    /// The branch the bar acts on: the selected file's in GitButler, the checked-out one in plain git.
    private var branch: HistoryBranch? {
        let name: String? = session.project.kind == .gitButler
            ? session.selectedFile.flatMap { session.assignedBranch(of: $0.path) } ?? session.branchNames.first
            : session.currentBranch
        guard let name else { return nil }
        return session.history.groups.lazy.flatMap(\.branches).first { $0.name == name }
    }
}

/// The files opened lately as tabs, newest kept; the ones that do not fit go in an overflow list.
private struct FileTabs: View {
    let session: ProjectSession

    var body: some View {
        let files = session.tabFiles
        ViewThatFits(in: .horizontal) {
            ForEach((1...max(files.count, 1)).reversed(), id: \.self) { shown in
                row(files, shown: shown)
            }
        }
    }

    /// The selected tab always shows; the rest fill up from the newest.
    private func row(_ files: [ChangedFile], shown: Int) -> some View {
        let visible = visibleFiles(files, count: shown)
        let hiddenCount = files.count - visible.count
        return HStack(spacing: 2) {
            ForEach(visible) { file in
                FileTab(file: file, isSelected: file.id == session.selectedFileID) {
                    session.closeTab(file.id)
                }
                .onTapGesture { session.selectedFileID = file.id }
            }
            if hiddenCount > 0 {
                TabOverflowButton(session: session, files: files, hiddenCount: hiddenCount)
                    .padding(.leading, 2)
            }
        }
        .fixedSize()
    }

    private func visibleFiles(_ files: [ChangedFile], count: Int) -> [ChangedFile] {
        guard files.count > count else { return files }
        var picked = Array(files.suffix(count))
        if let selected = files.first(where: { $0.id == session.selectedFileID }), !picked.contains(where: { $0.id == selected.id }) {
            picked.removeFirst()
            picked.append(selected)
        }
        return files.filter { file in picked.contains { $0.id == file.id } }
    }
}

/// An open file: its change letter and name. The selected tab sits raised; hovered ones get a fill.
struct FileTab: View {
    let file: ChangedFile
    let isSelected: Bool
    var onClose: (() -> Void)?

    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Text(FileBadge(kind: file.kind).letter)
                .font(.statusLetter)
                .foregroundStyle(Theme.changeColor(file.kind))
            Text((file.path as NSString).lastPathComponent)
                // One weight, so the tabs keep their width as the selection moves.
                .font(.control.weight(.medium))
                .foregroundStyle(isSelected ? Theme.textPrimary : isHovered ? Theme.textSecondary : Theme.textTertiary)
                .lineLimit(1)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(isCloseHovered ? Theme.textPrimary : Theme.textTertiary)
                        .frame(width: 16, height: 16)
                        .background(isCloseHovered ? Theme.selected : .clear, in: .rect(cornerRadius: 4))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { isCloseHovered = $0 }
                // Room is kept so tabs do not shift; the ✕ shows on the selected and hovered tab.
                .opacity(isSelected || isHovered ? 1 : 0)
                .help("Close Tab  ⌘W")
                .padding(.trailing, -4)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.raised : isHovered ? Theme.hover : .clear)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 0.5)
                    }
                }
                .shadow(color: .black.opacity(isSelected ? 0.06 : 0), radius: 1, y: 0.5)
        }
        .contentShape(.rect(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// `⌄ 3`: the tabs that do not fit; opens a list of every open tab to switch to or close.
private struct TabOverflowButton: View {
    let session: ProjectSession
    let files: [ChangedFile]
    let hiddenCount: Int

    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 4) {
                Text("+\(hiddenCount)")
                    .font(.detail.weight(.medium))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(isPresented ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(.rect)
        }
        .buttonStyle(.hover(cornerRadius: 8, isSelected: isPresented))
        .fixedSize()
        .focusEffectDisabled()
        .glassTooltip("Show All Tabs")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            OpenTabsPanel(session: session, files: files) { isPresented = false }
        }
    }
}

/// Every open tab, newest first, with arrows, return and escape like the launcher.
private struct OpenTabsPanel: View {
    let session: ProjectSession
    let files: [ChangedFile]
    let dismiss: () -> Void

    @State private var highlighted: ChangedFile.ID?

    private var ordered: [ChangedFile] { files.reversed() }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Open Tabs")
                .font(.caption11.weight(.medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ordered) { file in
                        OpenTabRow(
                            file: file,
                            isSelected: file.id == session.selectedFileID,
                            isHighlighted: file.id == highlighted,
                            choose: { choose(file) },
                            close: { session.closeTab(file.id) })
                        .onHover { if $0 { highlighted = file.id } }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
        }
        .padding(6)
        .frame(width: 320)
        .onAppear { highlighted = session.selectedFileID ?? ordered.first?.id }
        .paletteKeys(
            up: { move(-1) }, down: { move(1) },
            choose: { ordered.first { $0.id == highlighted }.map(choose) },
            dismiss: dismiss)
    }

    private func choose(_ file: ChangedFile) {
        session.selectedFileID = file.id
        dismiss()
    }

    private func move(_ offset: Int) {
        let ids = ordered.map(\.id)
        guard !ids.isEmpty else { return }
        let index = highlighted.flatMap(ids.firstIndex(of:)) ?? 0
        highlighted = ids[(index + offset + ids.count) % ids.count]
    }
}

private struct OpenTabRow: View {
    let file: ChangedFile
    let isSelected: Bool
    let isHighlighted: Bool
    let choose: () -> Void
    let close: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Text(FileBadge(kind: file.kind).letter)
                    .font(.statusLetter)
                    .foregroundStyle(Theme.changeColor(file.kind))
                    .frame(width: 12)
                Text((file.path as NSString).lastPathComponent)
                    .font(.control.weight(.medium))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text((file.path as NSString).deletingLastPathComponent)
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if isHighlighted {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.hover(cornerRadius: 4))
                    .help("Close Tab")
                } else if isSelected {
                    Circle()
                        .fill(Theme.textSecondary)
                        .frame(width: 5, height: 5)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(isHighlighted ? Theme.hover : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// `↓`: fetches, or opens the update once the remote has something new. Plain git labels it `Fetch`.
private struct FetchButton: View {
    let model: AppModel
    let session: ProjectSession
    let isLabeled: Bool

    var body: some View {
        let hasUpdates = session.upstream?.hasUpdates == true
        Button {
            if hasUpdates {
                model.isUpstreamUpdatePresented = true
            } else {
                Task { await session.fetch() }
            }
        } label: {
            HStack(spacing: 6) {
                if session.isFetching {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                } else {
                    Image(systemName: session.fetchError != nil ? "exclamationmark.triangle" : isLabeled && !hasUpdates ? "arrow.clockwise" : "arrow.down")
                        .font(.system(size: 12))
                        .foregroundStyle(session.fetchError != nil ? Theme.warnFg : hasUpdates ? Theme.textPrimary : Theme.textSecondary)
                        .frame(width: 14, height: 14)
                }
                if hasUpdates, let upstream = session.upstream {
                    Text(UpstreamControls.updateTitle(upstream))
                        .font(.control.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                } else if isLabeled {
                    Text("Fetch")
                        .font(.control.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.hover(cornerRadius: 8))
        .disabled(session.isFetching || session.isUpdatingFromUpstream)
        .focusEffectDisabled()
        .glassTooltip(tooltip)
    }

    private var tooltip: String {
        if let error = session.fetchError { return "Fetch failed: \(error)" }
        if session.upstream?.hasUpdates == true { return "Review and Update…  ⇧⌘U" }
        let fetched = session.lastFetched.map { " · fetched \(UpstreamControls.fetchedTitle($0).lowercased())" } ?? ""
        return "Fetch from \(session.upstream?.target ?? "the remote")\(fetched)  ⇧⌘F"
    }
}

/// `↑ Push 2`: the branch's unpushed commits.
private struct PushButton: View {
    let history: HistoryModel
    let branch: HistoryBranch

    var body: some View {
        Button { history.requestPush(branch) } label: {
            HStack(spacing: 6) {
                if history.branchActivity == "Pushing…" {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12))
                        .frame(width: 14, height: 14)
                }
                Text("Push")
                    .font(.control.weight(.medium))
                if unpushed > 0 {
                    Text("\(unpushed)")
                        .font(.caption11)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(.pill(height: 28))
        .disabled(!history.canPush(branch) || history.branchActivity != nil)
        .focusEffectDisabled()
        .glassTooltip(branch.needsForcePush ? "Force Push \(branch.name)…  ⇧⌘P" : "Push \(branch.name)  ⇧⌘P")
    }

    private var unpushed: Int {
        switch branch.status {
        case .tracking(let ahead, _)?: ahead
        case .unpushed?, .unpushedCommits?, .requiresForce?, nil: history.canPush(branch) ? branch.commits.count : 0
        default: 0
        }
    }
}

/// `⇅ #142 ◌ 3/5`: the branch's pull request and its checks; opens it on GitHub.
private struct PullRequestButton: View {
    let history: HistoryModel
    let pullRequest: PullRequest

    var body: some View {
        Button { NSWorkspace.shared.open(pullRequest.url) } label: {
            HStack(spacing: 6) {
                Image(systemName: pullRequest.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                    .font(.system(size: 12))
                    .frame(width: 14, height: 14)
                Text("#\(pullRequest.number)")
                    .font(.control.weight(.medium))
                    .monospacedDigit()
                if let checks = history.pullRequestStatuses[pullRequest.number]?.checks {
                    ChecksChip(checks: checks, isCompact: true)
                }
            }
        }
        .buttonStyle(.pill(height: 28))
        .focusEffectDisabled()
        .glassTooltip(pullRequest.title)
    }
}

/// A page's name at the start of its bar.
struct PageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.row.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.leading, 6)
            .padding(.trailing, 10)
    }
}

/// History: the branch filter, the search, display options and the inspector.
private struct HistoryTopBar: View {
    let session: ProjectSession
    @Bindable var log: CommitLogModel
    @AppStorage(AppSettings.isInspectorShownKey) private var isInspectorShown = true
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        PageTitle(title: "History")
        Segmented(selection: $log.filter, options: filters, systemImages: icons)
        Spacer(minLength: 8)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .frame(width: 13, height: 13)
            TextField("Message, author or SHA", text: $log.search)
                .textFieldStyle(.plain)
                .font(.control)
                .foregroundStyle(Theme.textPrimary)
                .focused($isSearchFocused)
                .onExitCommand {
                    log.search = ""
                    isSearchFocused = false
                }
            KeyCap("/")
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 8)
        .frame(width: 260, height: 28)
        .background(Theme.hover, in: .rect(cornerRadius: 8))
        .background {
            Button("") { isSearchFocused = true }
                .keyboardShortcut("/", modifiers: [])
                .hidden()
        }
        .padding(.trailing, 8)
        Menu {
            Toggle("Show Merge Commits", isOn: $log.showsMerges)
            Toggle("Only My Commits", isOn: $log.onlyMine)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14))
                .foregroundStyle(log.showsMerges && !log.onlyMine ? Theme.textSecondary : Theme.textPrimary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hover(cornerRadius: 8, isSelected: !log.showsMerges || log.onlyMine))
        .fixedSize()
        .padding(.trailing, 8)
        IconButton(isInspectorShown ? "Hide Inspector  ⌥⌘I" : "Show Inspector  ⌥⌘I", systemImage: "sidebar.right", isSelected: isInspectorShown) {
            withAnimation(.snappy(duration: 0.2)) { isInspectorShown.toggle() }
        }
    }

    /// All branches, the branch being worked on, and the default branch.
    private var filters: [(value: CommitLogModel.Filter, title: String)] {
        var result: [(value: CommitLogModel.Filter, title: String)] = [(.all, "All branches")]
        let current = session.currentBranch ?? session.history.selectedBranch?.name ?? session.branchNames.first
        if let current, current != log.defaultBranch { result.append((.branch(current), current)) }
        if let main = log.defaultBranch { result.append((.branch(main), main)) }
        return result
    }

    private var icons: [CommitLogModel.Filter: String] {
        var icons: [CommitLogModel.Filter: String] = [:]
        for filter in filters {
            if case .branch(let name) = filter.value, name != log.defaultBranch { icons[filter.value] = "arrow.triangle.branch" }
        }
        return icons
    }
}
