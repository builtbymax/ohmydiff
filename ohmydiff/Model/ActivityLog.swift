import Foundation
import Observation
import SwiftUI

/// What ran lately and what runs now, for the sidebar's Activity: pushes, merges, AI drafts and what the
/// toasts reported.
@MainActor @Observable
final class ActivityLog {
    static let shared = ActivityLog()

    struct Entry: Identifiable {
        enum Kind { case running, ai, done, failed }

        let id = UUID()
        var title: String
        var detail: String
        var kind: Kind
        var date = Date.now
    }

    /// Newest first, at most `limit`.
    private(set) var entries: [Entry] = []
    private let limit = 20

    /// Starts an entry for something that takes a while; `finish` removes it.
    @discardableResult
    func begin(_ title: String, detail: String = "", isAI: Bool = false) -> Entry.ID {
        let entry = Entry(title: title, detail: detail, kind: isAI ? .ai : .running)
        insert(entry)
        return entry.id
    }

    /// Ends a running entry; a failure stays listed.
    func finish(_ id: Entry.ID, failure: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let failure {
            entries[index].kind = .failed
            entries[index].detail = failure
            entries[index].date = .now
        } else {
            entries.remove(at: index)
        }
    }

    func record(_ title: String, detail: String = "", failed: Bool = false) {
        insert(Entry(title: title, detail: detail, kind: failed ? .failed : .done))
    }

    private func insert(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }
}
