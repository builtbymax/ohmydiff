import AppKit
import OhMyDiffCore
import SwiftUI

/// The glass rail on the left: the logo, Changes / History, the project switcher and one tile per project.
struct RailView: View {
    @Bindable var model: AppModel
    @Binding var mode: WorkspaceMode

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 6) {
                // Room for the window controls, which sit on the rail.
                Color.clear.frame(height: 24)

                Text("±")
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Theme.logo, in: .circle)
                    .padding(.bottom, 14)
                    .accessibilityHidden(true)

                RailButton(title: "Changes", systemImage: "plusminus", isSelected: mode == .changes) { mode = .changes }
                RailButton(title: "History", systemImage: "clock", isSelected: mode == .history) { mode = .history }
                RailButton(title: "Switch Project (⌘K)", systemImage: "magnifyingglass", isSelected: false) {
                    model.isSwitcherPresented = true
                }
                .disabled(model.projects.isEmpty)

                Divider()
                    .frame(width: 28)
                    .padding(.vertical, 8)

                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(model.projects) { project in
                            ProjectTile(
                                project: project, session: model.session(for: project.id),
                                isSelected: project.id == model.selectedProjectID
                            ) {
                                model.selectedProjectID = project.id
                            }
                            .contextMenu { contextMenu(for: project) }
                        }
                        Button { model.isImporterPresented = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, height: 40)
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                .contentShape(.rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .help("Add Project (⇧⌘O)")
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)

                Spacer(minLength: 8)

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.vertical, 12)
            .frame(width: Theme.railWidth)
            .frame(maxHeight: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .gesture(WindowDragGesture())
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            Task { await model.addProjects(folders) }
            return true
        }
    }

    @ViewBuilder
    private func contextMenu(for project: Project) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        }
        .disabled(!project.exists)
        Button("Refresh") { model.session(for: project.id).refresh() }
        Divider()
        Button("Remove Project", role: .destructive) { model.remove(project.id) }
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
                .frame(width: 44, height: 44)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 14).fill(Theme.glassSelection)
                    }
                }
                .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A project as a two-letter monogram, with its change count.
private struct ProjectTile: View {
    let project: Project
    let session: ProjectSession
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(Self.monogram(project.displayName))
                .font(.system(size: 14, weight: isSelected ? .bold : .semibold))
                .foregroundStyle(session.phase == .missing ? AnyShapeStyle(.orange) : isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 40, height: 40)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.background.opacity(0.9))
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if session.changeCount > 0 {
                        Text("\(session.changeCount)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Color.accentColor, in: .capsule)
                            .offset(x: 5, y: -4)
                    }
                }
                .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(session.phase == .missing ? "\(project.displayName) (missing)" : "\(project.displayName)\n\(project.path)")
        .accessibilityLabel(project.displayName)
    }

    /// `ohmydiff-large-diff` → `ol`, `family` → `fa`.
    static func monogram(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let letters = words.count > 1 ? [words.first!.first!, words.last!.first!] : Array(name.prefix(2))
        return String(letters).lowercased()
    }
}
