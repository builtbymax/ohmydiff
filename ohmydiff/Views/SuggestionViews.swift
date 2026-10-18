import OhMyDiffCore
import SwiftUI

/// A small "✦ Generate" button for AI suggestions, with a spinner while one runs.
struct SuggestButton: View {
    let title: String
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(isRunning ? "Generating…" : title)
            }
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.pill(height: 24))
        .disabled(isRunning)
        .focusEffectDisabled()
    }
}

/// Why a suggestion failed, with a way to Settings when no provider is chosen.
struct SuggestionNotice: View {
    let error: Error
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if case SuggestionUnavailable.noProvider = error {
                Label("No AI Provider is selected", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Choose in Settings…") { SettingsWindow.open(.ai, with: openSettings) }
                    .buttonStyle(.pill(height: 24))
                    .font(.caption.weight(.semibold))
                    .focusEffectDisabled()
            } else {
                Label(String(describing: error), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.deletion)
                    .textSelection(.enabled)
                    .lineLimit(4)
                Spacer(minLength: 0)
            }
        }
    }
}

/// The ticket a suggestion refers to: found from the branch name, or picked by searching the connected trackers.
struct TicketField: View {
    @Binding var ticket: Ticket?
    /// Whether a ticket is being looked up from the branch name.
    var isDetecting = false
    let resolver: TicketResolver
    /// Called when the user links or unlinks a ticket, so detection stops replacing it.
    var onChoose: () -> Void = {}

    @State private var isSearching = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ticket")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            if let ticket {
                Text(ticket.id)
                    .font(.callout.monospaced().weight(.semibold))
                Text(ticket.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(ticket.title)
                Spacer(minLength: 4)
                Button {
                    self.ticket = nil
                    onChoose()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Unlink Ticket")
            } else {
                Text(isDetecting ? "Looking for a ticket…" : "No ticket linked")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            Button(ticket == nil ? "Link…" : "Change…") { isSearching = true }
                .buttonStyle(.pill(height: 24))
                .font(.caption.weight(.semibold))
                .popover(isPresented: $isSearching, arrowEdge: .bottom) {
                    TicketSearch(resolver: resolver) { picked in
                        ticket = picked
                        isSearching = false
                        onChoose()
                    }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .fieldBackground(isFocused: false)
        .focusEffectDisabled()
    }
}

/// Searches the connected trackers as the user types.
private struct TicketSearch: View {
    let resolver: TicketResolver
    let pick: (Ticket) -> Void

    @State private var query = ""
    @State private var results: [Ticket] = []
    @State private var isLoading = false
    @State private var error: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $query, prompt: Text("Search tickets or type an ID, e.g. HAL-128"))
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
            Group {
                if isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(Theme.deletion)
                } else if results.isEmpty {
                    Text(query.isEmpty ? "Searches \(resolver.providers.map(\.source.displayName).joined(separator: ", "))." : "No tickets found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(results, id: \.self) { ticket in
                                Button { pick(ticket) } label: {
                                    HStack(spacing: 8) {
                                        Text(ticket.id).font(.callout.monospaced().weight(.semibold))
                                        Text(ticket.title).font(.callout).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(ticket.source.displayName).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.row(isSelected: false))
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(width: 380)
        .onAppear { isFocused = true }
        .task(id: query) {
            let query = query.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else {
                results = []
                error = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                let found = try await resolver.search(query)
                guard !Task.isCancelled else { return }
                results = found
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = String(describing: error)
            }
        }
    }
}
