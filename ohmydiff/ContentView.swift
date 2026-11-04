import AppKit
import OhMyDiffCore
import SwiftUI
import UniformTypeIdentifiers

/// The pages of the sidebar.
enum WorkspaceMode: String, CaseIterable, Identifiable {
    /// Uncommitted changes, branches and their commits.
    case branches = "Branches"
    case pullRequests = "Pull requests"
    case history = "History"

    var id: Self { self }
    var title: String { rawValue }

    /// The pages built so far, in sidebar order.
    static let available: [WorkspaceMode] = [.branches, .pullRequests, .history]

    var systemImage: String {
        switch self {
        case .branches: "arrow.triangle.branch"
        case .pullRequests: "arrow.triangle.pull"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// ⌘1–⌘3 unless changed in Settings → Shortcuts.
    var shortcutAction: ShortcutAction {
        switch self {
        case .branches: .branches
        case .pullRequests: .pullRequests
        case .history: .history
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel

    @AppStorage(AppSettings.isSidebarHiddenKey) private var isSidebarHidden = false
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppAppearance.system

    var body: some View {
        HStack(spacing: 0) {
            if !isSidebarHidden {
                SidebarView(model: model, isHidden: $isSidebarHidden)
                    .padding(.top, Theme.inset)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                if isSidebarHidden {
                    collapsedTitleBar
                }
                panel
                    .padding(.top, isSidebarHidden ? 0 : Theme.inset)
                    .padding(.bottom, Theme.inset)
                    .padding(.trailing, Theme.inset)
                    .padding(.leading, isSidebarHidden ? Theme.inset : 1)
            }
        }
        .background(Theme.sidebar)
        .ignoresSafeArea()
        .focusedSceneValue(\.isMainWindow, true)
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if model.isProjectMenuPresented {
                    ProjectSwitcher(model: model)
                }
                if model.isWorkspaceMenuPresented {
                    WorkspaceDropdown(model: model)
                }
            }
            .animation(Theme.popoverAnimation, value: model.isProjectMenuPresented)
            .animation(Theme.popoverAnimation, value: model.isWorkspaceMenuPresented)
        }
        .overlay {
            ZStack {
                if model.isSwitcherPresented {
                    CommandPalette(model: model)
                }
            }
            .animation(Theme.launcherAnimation, value: model.isSwitcherPresented)
        }
        .frame(minWidth: 900, minHeight: 560)
        .task(id: appearance) { appearance.apply() }
        .task(id: model.selectedSession?.lastRefreshed) {
            // The sidebar lists the project's branches and pull requests on every page.
            await model.selectedSession?.refreshHistory()
        }
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.addProjects(urls) }
        }
        .sheet(isPresented: $model.isUpstreamUpdatePresented) {
            if let session = model.selectedSession {
                UpstreamUpdateSheet(session: session)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Add this repository?",
            isPresented: Binding(get: { model.pendingURLRequest != nil }, set: { if !$0 { model.pendingURLRequest = nil } }),
            presenting: model.pendingURLRequest
        ) { request in
            Button("Add Project") { model.confirm(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("A link or another app asked ohmydiff to open \(request.folder.path). Adding it runs git and but in that folder, so only add repositories you trust.")
        }
        .alert(
            "Delete “\(model.pendingWorkspaceDeletion?.name ?? "")”?",
            isPresented: Binding(get: { model.pendingWorkspaceDeletion != nil }, set: { if !$0 { model.pendingWorkspaceDeletion = nil } }),
            presenting: model.pendingWorkspaceDeletion
        ) { workspace in
            Button("Delete", role: .destructive) { model.deleteWorkspace(workspace.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The workspace is empty. Deleting it cannot be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Catch up on anything the watcher cannot see, e.g. changes made while the Mac slept.
            model.refreshSelected()
        }
        .onChange(of: isSidebarHidden) { model.isProjectMenuPresented = false }
        .onReceive(NotificationCenter.default.publisher(for: .showUpstreamUpdate)) { _ in model.isUpstreamUpdatePresented = true }
    }

    /// With the sidebar hidden, the window controls and the button that brings the sidebar back share a row
    /// above the panel, instead of the button sitting lower in the panel's bar. The button lives in the title
    /// bar itself: views laid out under the hidden title bar do not get its clicks.
    private var collapsedTitleBar: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.titleBarHeight)
            .contentShape(.rect)
            .gesture(WindowDragGesture())
            .background {
                WindowControlsAccessory {
                    IconButton("Show Sidebar  ⌃⌘S", systemImage: "sidebar.left") {
                        withAnimation(.snappy(duration: 0.2)) { isSidebarHidden = false }
                    }
                }
            }
    }

    /// The window controls' row: they sit centred in it.
    static let titleBarHeight: CGFloat = 30

    /// The content panel: the page's top bar over its body.
    private var panel: some View {
        VStack(spacing: 0) {
            // Content wider than the window is cut off on the right; it never pushes the sidebar out.
            PageTopBar(model: model, mode: model.mode)
            Rectangle().fill(Theme.lineSubtle).frame(height: 1)
            pageBody
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            ToastStack(toasts: .shared)
                .padding(.top, 44 + 20)
                .padding(.trailing, 20)
        }
        .updateBar(Updater.shared)
        .background(Theme.canvas)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.lineSubtle))
        .background { RoundedRectangle(cornerRadius: 12).fill(Theme.canvas).shadow(color: Theme.cardShadow, radius: 1.5, y: 1) }
    }

    @ViewBuilder
    private var pageBody: some View {
        if let session = model.selectedSession {
            switch model.mode {
            case .branches:
                BranchesPageView(model: model, session: session)
            case .pullRequests:
                PullRequestsPageView(model: model, session: session)
            case .history:
                HistoryPageView(model: model, session: session)
            }
        } else if model.projects.isEmpty {
            FirstRunView(model: model)
        } else {
            let title = model.projects.isEmpty ? "No projects yet" : "No projects in \(model.selectedWorkspace?.name ?? "this workspace")"
            EmptyState(title, systemImage: "folder", description: "Add a git repository, or drop a folder on the sidebar.") {
                Button("Add project…") { model.isImporterPresented = true }
                    .buttonStyle(.pill(.prominent))
            }
        }
    }
}

#Preview {
    ContentView(model: AppModel())
}

/// Shows a view in the window's title bar, level with the window controls, for as long as it is in the hierarchy:
/// right of them, or ending `trailingX` points from the window's left edge. The title bar sits above the content,
/// so this is the only way for a control beside the window controls to receive clicks.
struct WindowControlsAccessory<Content: View>: NSViewRepresentable {
    var trailingX: CGFloat?
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.trailingX = trailingX
        anchor.show(AnyView(content))
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) {
        anchor.remove()
    }

    final class Anchor: NSView {
        private var hostingView: NSHostingView<AnyView>?
        private var content: AnyView?
        var trailingX: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { remove() } else { install() }
        }

        func show(_ content: AnyView) {
            self.content = content
            install()
        }

        func remove() {
            hostingView?.removeFromSuperview()
            hostingView = nil
        }

        private func install() {
            guard let content, let zoom = window?.standardWindowButton(.zoomButton), let titleBar = zoom.superview else { return }
            let hostingView = hostingView ?? NSHostingView(rootView: content)
            hostingView.rootView = content
            if hostingView.superview !== titleBar {
                titleBar.addSubview(hostingView)
                self.hostingView = hostingView
            }
            let size = hostingView.fittingSize
            hostingView.frame = NSRect(
                x: trailingX.map { $0 - size.width } ?? zoom.frame.maxX + 10, y: zoom.frame.midY - size.height / 2, width: size.width, height: size.height)
            // Stays beside the window controls as the title bar resizes, wherever its origin is.
            hostingView.autoresizingMask = titleBar.isFlipped ? [.maxXMargin, .maxYMargin] : [.maxXMargin, .minYMargin]
        }
    }
}
