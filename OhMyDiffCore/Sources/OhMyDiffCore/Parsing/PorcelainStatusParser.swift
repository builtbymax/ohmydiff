import Foundation

/// One entry of `git status --porcelain=v2 -z`.
public struct StatusEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case ordinary
        case renamed
        case copied
        case unmerged
        case untracked
        case ignored
    }

    public var kind: Kind
    public var path: String
    /// Source path for renames and copies.
    public var originalPath: String?
    /// The `X` status code (index vs. HEAD); `.` when unchanged.
    public var indexStatus: Character
    /// The `Y` status code (worktree vs. index); `.` when unchanged.
    public var worktreeStatus: Character
    public var similarity: Int?

    public init(
        kind: Kind, path: String, originalPath: String? = nil,
        indexStatus: Character = ".", worktreeStatus: Character = ".", similarity: Int? = nil
    ) {
        self.kind = kind
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.similarity = similarity
    }

    public var isStaged: Bool { kind != .untracked && kind != .ignored && kind != .unmerged && indexStatus != "." }
    public var isUnstaged: Bool { kind != .untracked && kind != .ignored && kind != .unmerged && worktreeStatus != "." }
}

public enum PorcelainStatusParser {
    public static func parse(_ data: Data) -> [StatusEntry] {
        var records = data.split(separator: 0, omittingEmptySubsequences: true).map {
            String(decoding: $0, as: UTF8.self)
        }[...]
        var entries: [StatusEntry] = []

        while let record = records.popFirst() {
            guard let tag = record.first else { continue }
            switch tag {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                let (x, y) = statusCodes(fields[1])
                entries.append(StatusEntry(kind: .ordinary, path: String(fields[8]), indexStatus: x, worktreeStatus: y))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path, followed by a NUL-separated original path
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10 else { continue }
                let (x, y) = statusCodes(fields[1])
                let score = fields[8]
                let original = records.popFirst()
                entries.append(StatusEntry(
                    kind: score.first == "C" ? .copied : .renamed,
                    path: String(fields[9]), originalPath: original,
                    indexStatus: x, worktreeStatus: y, similarity: Int(score.dropFirst())))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                let (x, y) = statusCodes(fields[1])
                entries.append(StatusEntry(kind: .unmerged, path: String(fields[10]), indexStatus: x, worktreeStatus: y))
            case "?":
                entries.append(StatusEntry(kind: .untracked, path: String(record.dropFirst(2)), indexStatus: "?", worktreeStatus: "?"))
            case "!":
                entries.append(StatusEntry(kind: .ignored, path: String(record.dropFirst(2)), indexStatus: "!", worktreeStatus: "!"))
            default:
                // `#` headers and anything unknown.
                continue
            }
        }
        return entries
    }

    private static func statusCodes(_ field: Substring) -> (Character, Character) {
        let chars = Array(field)
        return (chars.first ?? ".", chars.count > 1 ? chars[1] : ".")
    }
}

extension StatusEntry {
    /// Maps a porcelain status code to a change kind.
    static func changeKind(for code: Character) -> FileChangeKind {
        switch code {
        case "A": .added
        case "D": .deleted
        case "M": .modified
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "?": .untracked
        case "U": .conflicted
        default: .unknown
        }
    }
}
