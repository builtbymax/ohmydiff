import OhMyDiffCore
import SwiftUI

/// ⌘K palette: fuzzy-filter projects by name and jump with Return.
struct ProjectSwitcher: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isSearchFocused: Bool

    private var results: [(item: Project, match: FuzzyMatcher.Match)] {
        FuzzyMatcher.rank(model.projects, query: query) { $0.displayName }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Switch to project…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($isSearchFocused)
                .onSubmit(choose)
                .onKeyPress(.downArrow) { moveHighlight(1) }
                .onKeyPress(.upArrow) { moveHighlight(-1) }
                .onChange(of: query) { highlighted = 0 }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.item.id) { offset, result in
                            row(result.item, match: result.match, isHighlighted: offset == highlighted)
                                .id(offset)
                                .onTapGesture {
                                    highlighted = offset
                                    choose()
                                }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
            .frame(height: 280)
            .overlay {
                if results.isEmpty {
                    Text(model.projects.isEmpty ? "No projects yet" : "No matching projects")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 480)
        .onAppear { isSearchFocused = true }
        .onExitCommand { dismiss() }
    }

    private func row(_ project: Project, match: FuzzyMatcher.Match, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: project.kind == .gitButler ? "square.stack.3d.up" : "folder")
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlightedName(project.displayName, indices: match.indices))
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if let position = model.projects.firstIndex(of: project), position < 9 {
                Text("⌘\(position + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
        }
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
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
