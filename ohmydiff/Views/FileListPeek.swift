import OhMyDiffCore
import SwiftUI

/// A file of the list the diff belongs to, for the floating list.
struct FileListItem: Identifiable {
    let id: String
    let path: String
    var previousPath: String?
    let kind: FileChangeKind
    let stats: LineStats?
}

/// The file list's toggle in the file header. While the list is hidden, it also shows the files' count and line
/// totals; resting the pointer on them shows the list floating over the diff.
struct FileListToggle {
    let count: Int
    let stats: LineStats
    /// Whether the pointer rests on the count.
    let hover: (Bool) -> Void
}

extension EnvironmentValues {
    /// Set where the diff sits beside a file list that can be hidden.
    @Entry var fileListToggle: FileListToggle?
}

/// `▯ 16 +739 −498`: shows or hides the file list; the count stands in for the hidden list.
struct FileListToggleControl: View {
    let toggle: FileListToggle

    @AppStorage(AppSettings.isListHiddenKey) private var isListHidden = false

    var body: some View {
        HStack(spacing: 2) {
            IconButton(isListHidden ? "Show File List  ⌘0" : "Hide File List  ⌘0", systemImage: "sidebar.left", size: 26) {
                withAnimation(.snappy(duration: 0.2)) { isListHidden.toggle() }
            }
            if isListHidden {
                HStack(spacing: 6) {
                    Text("\(toggle.count)")
                        .font(.caption11.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                    LineStatsLabel(stats: toggle.stats)
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(Theme.hover, in: .rect(cornerRadius: 7))
                .contentShape(.rect)
                .onHover(perform: toggle.hover)
                .accessibilityLabel("\(toggle.count) files")
            }
        }
        .fixedSize()
    }
}

/// The hidden file list, floating over the diff while the pointer rests on its count or on the list.
struct FloatingFileList: View {
    let items: [FileListItem]
    let selectedID: String?
    let select: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        let isSelected = item.id == selectedID
                        Button { select(item.id) } label: {
                            FileRow(path: item.path, previousPath: item.previousPath, kind: item.kind, stats: item.stats, isSelected: isSelected)
                        }
                        .buttonStyle(.row(isSelected: isSelected))
                        .focusEffectDisabled()
                        .id(item.id)
                    }
                }
                .padding(6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onAppear { selectedID.map { proxy.scrollTo($0, anchor: .center) } }
        }
        .frame(width: 360)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .popoverSurface(in: .rect(cornerRadius: 12))
    }
}

extension View {
    /// Gives the file header the file list's toggle, and floats the hidden list over the diff while peeking.
    func fileListPeek(
        _ list: (items: [FileListItem], selectedID: String?, select: (String) -> Void), isPeeking: Bool, toggle: FileListToggle,
        hover: @escaping (Bool) -> Void
    ) -> some View {
        environment(\.fileListToggle, toggle)
            .overlay(alignment: .topLeading) {
                if isPeeking, !list.items.isEmpty {
                    FloatingFileList(items: list.items, selectedID: list.selectedID, select: list.select)
                        .onHover(perform: hover)
                        // Just under the count in the file header.
                        .padding(.top, 40)
                        .padding(.leading, 8)
                        .popoverTransition(anchor: .topLeading)
                }
            }
    }
}
