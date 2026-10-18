import OhMyDiffCore
import SwiftUI

/// ⌘K palette floating over the window: fuzzy-filter projects by name and jump with Return.
struct ProjectSwitcher: View {
    let model: AppModel

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isSearchFocused: Bool

    private var results: [(item: Project, match: FuzzyMatcher.Match)] {
        FuzzyMatcher.rank(model.projects, query: query) { $0.displayName }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            palette
                .padding(.top, 90)
        }
        .transition(.opacity)
    }

    private var palette: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Switch to project…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit(choose)
                    .onKeyPress(.downArrow) { moveHighlight(1) }
                    .onKeyPress(.upArrow) { moveHighlight(-1) }
                    .onChange(of: query) { highlighted = 0 }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(results.enumerated()), id: \.element.item.id) { offset, result in
                            row(result.item, match: result.match, isHighlighted: offset == highlighted)
                                .id(offset)
                                .onTapGesture {
                                    highlighted = offset
                                    choose()
                                }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            .overlay {
                if results.isEmpty {
                    Text(model.projects.isEmpty ? "No projects yet" : "No matching projects")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 520)
        .glassEffect(Theme.barGlass, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .onAppear { isSearchFocused = true }
        .onExitCommand(perform: dismiss)
    }

    private func dismiss() {
        model.isSwitcherPresented = false
    }

    private func row(_ project: Project, match: FuzzyMatcher.Match, isHighlighted: Bool) -> some View {
        let session = model.session(for: project.id)
        return HStack(spacing: 12) {
            Text(projectMonogram(project.displayName))
                .font(.system(size: 12, weight: .bold))
                .frame(width: 32, height: 32)
                .background(Theme.glassSelection, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(highlightedName(project.displayName, indices: match.indices))
                    Text(project.kind == .gitButler ? "GitButler" : "Git")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(project.kind == .gitButler ? Color.green : Color.secondary)
                }
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if session.changeCount > 0 {
                Text(session.changeCount == 1 ? "1 change" : "\(session.changeCount) changes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let position = model.projects.firstIndex(of: project), position < 9 {
                Text("⌘\(position + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHighlighted ? Theme.glassSelection : .clear, in: .rect(cornerRadius: 12))
        .contentShape(.rect)
    }

    private func highlightedName(_ name: String, indices: [Int]) -> AttributedString {
        var result = AttributedString()
        let matched = Set(indices)
        for (offset, character) in name.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
        }
        return result
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        highlighted = (highlighted + delta + results.count) % results.count
        return .handled
    }

    private func choose() {
        guard results.indices.contains(highlighted) else { return }
        model.selectedProjectID = results[highlighted].item.id
        dismiss()
    }
}
