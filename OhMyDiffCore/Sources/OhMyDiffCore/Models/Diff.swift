/// How a file changed between two trees.
public enum FileChangeKind: String, Sendable, Hashable, Codable {
    case added
    case deleted
    case modified
    case renamed
    case copied
    case typeChanged
    case untracked
    case conflicted
    case unknown
}

/// One file in a unified diff.
public struct FileDiff: Sendable, Hashable, Identifiable {
    /// Path before the change; `nil` for added files.
    public var oldPath: String?
    /// Path after the change; `nil` for deleted files.
    public var newPath: String?
    public var kind: FileChangeKind
    public var oldMode: String?
    public var newMode: String?
    /// Similarity percentage for renames and copies.
    public var similarity: Int?
    public var isBinary: Bool
    public var hunks: [Hunk]

    public init(
        oldPath: String?, newPath: String?, kind: FileChangeKind,
        oldMode: String? = nil, newMode: String? = nil, similarity: Int? = nil,
        isBinary: Bool = false, hunks: [Hunk] = []
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.kind = kind
        self.oldMode = oldMode
        self.newMode = newMode
        self.similarity = similarity
        self.isBinary = isBinary
        self.hunks = hunks
    }

    /// The path to display: the new path, or the old one for deletions.
    public var path: String { newPath ?? oldPath ?? "" }
    public var id: String { "\(oldPath ?? "")\u{0}\(newPath ?? "")" }

    public var isModeChange: Bool {
        if let oldMode, let newMode { return oldMode != newMode }
        return false
    }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .addition } } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .deletion } } }
}

public struct Hunk: Sendable, Hashable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Text after the closing `@@`, usually the enclosing function.
    public var section: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String = "", lines: [DiffLine] = []) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }

    public var header: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" + (section.isEmpty ? "" : " \(section)")
    }
}

public struct DiffLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case context
        case addition
        case deletion
    }

    public var kind: Kind
    /// Line content without the leading marker or trailing newline.
    public var text: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?
    /// `true` when this line is followed by `\ No newline at end of file`.
    public var noNewlineAtEnd: Bool

    public init(kind: Kind, text: String, oldLineNumber: Int?, newLineNumber: Int?, noNewlineAtEnd: Bool = false) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.noNewlineAtEnd = noNewlineAtEnd
    }
}
