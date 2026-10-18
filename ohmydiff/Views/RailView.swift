import SwiftUI

/// The glass rail on the left: the logo, Changes / History, the project switcher and Settings.
/// Projects are switched from the breadcrumb in the toolbar.
struct RailView: View {
    @Bindable var model: AppModel
    @Binding var mode: WorkspaceMode

    var body: some View {
        VStack(spacing: 6) {
            Text("±")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(Theme.logo, in: .circle)
                .padding(.bottom, 12)
                .accessibilityHidden(true)

            RailButton(title: "Changes", systemImage: "plusminus", isSelected: mode == .changes) { mode = .changes }
            RailButton(title: "History", systemImage: "clock", isSelected: mode == .history) { mode = .history }
            RailButton(title: "Switch Project (⌘K)", systemImage: "magnifyingglass", isSelected: model.isSwitcherPresented) {
                model.isSwitcherPresented = true
            }
            .disabled(model.projects.isEmpty)

            Spacer(minLength: 8)

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .contentShape(.rect(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.vertical, 12)
        .frame(width: Theme.railWidth)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .gesture(WindowDragGesture())
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            Task { await model.addProjects(folders) }
            return true
        }
    }
}

private struct RailButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 42, height: 42)
                .background {
                    if isSelected { RoundedRectangle(cornerRadius: 13).fill(Theme.glassSelection) }
                }
                .contentShape(.rect(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A project as a two-letter monogram: `ohmydiff-large-diff` → `od`, `family` → `fa`.
func projectMonogram(_ name: String) -> String {
    let words = name.split { !$0.isLetter && !$0.isNumber }
    guard words.count > 1, let first = words.first?.first, let last = words.last?.first else {
        return String(name.prefix(2)).lowercased()
    }
    return String([first, last]).lowercased()
}
