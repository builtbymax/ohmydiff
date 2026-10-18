extension FileDiff {
    /// The diff as git prints it, for agents and prompts: a `diff --git` header, the `---`/`+++` lines
    /// and the hunks. Binary files get git's one-line note instead of hunks.
    public var patch: String {
        let old = oldPath ?? newPath ?? ""
        let new = newPath ?? oldPath ?? ""
        var text = "diff --git a/\(old) b/\(new)\n"
        switch kind {
        case .added, .untracked: text += "new file mode \(newMode ?? "100644")\n"
        case .deleted: text += "deleted file mode \(oldMode ?? "100644")\n"
        default:
            if isModeChange, let oldMode, let newMode { text += "old mode \(oldMode)\nnew mode \(newMode)\n" }
            if old != new { text += "rename from \(old)\nrename to \(new)\n" }
        }
        if isBinary {
            return text + "Binary files \(oldPath.map { "a/\($0)" } ?? "/dev/null") and \(newPath.map { "b/\($0)" } ?? "/dev/null") differ\n"
        }
        guard !hunks.isEmpty else { return text }
        text += "--- \(oldPath.map { "a/\($0)" } ?? "/dev/null")\n+++ \(newPath.map { "b/\($0)" } ?? "/dev/null")\n"
        for hunk in hunks { text += hunk.patch }
        return text
    }
}

extension Hunk {
    /// The header and lines with their `+`, `-` and ` ` markers.
    public var patch: String {
        var text = header + "\n"
        for line in lines {
            text += line.marker + line.text + "\n"
            if line.noNewlineAtEnd { text += "\\ No newline at end of file\n" }
        }
        return text
    }
}

extension DiffLine {
    public var marker: String {
        switch kind {
        case .context: " "
        case .addition: "+"
        case .deletion: "-"
        }
    }
}
