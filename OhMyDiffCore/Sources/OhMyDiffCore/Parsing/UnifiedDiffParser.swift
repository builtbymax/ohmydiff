import Foundation

/// Parses `git diff` style unified diffs (with `diff --git` headers) into `FileDiff`s.
public enum UnifiedDiffParser {
    public static func parse(_ data: Data) -> [FileDiff] {
        var parser = State()
        for line in data.lines() {
            parser.consume(line)
        }
        return parser.finish()
    }

    public static func parse(_ text: String) -> [FileDiff] {
        parse(Data(text.utf8))
    }

    private struct State {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: Hunk?
        var oldLine = 0
        var newLine = 0
        /// Remaining old/new line counts of the open hunk; a line starting with `---` inside a hunk is content.
        var oldRemaining = 0
        var newRemaining = 0

        mutating func consume(_ raw: Data) {
            let line = String(decoding: raw, as: UTF8.self)

            if hunk != nil {
                if consumeHunkLine(line) { return }
                closeHunk()
            }

            if line.hasPrefix("diff --git ") {
                closeFile()
                current = Self.fileFromGitHeader(String(line.dropFirst("diff --git ".count)))
                return
            }
            guard current != nil else { return }

            if line.hasPrefix("@@ ") {
                openHunk(line)
            } else if line.hasPrefix("--- ") {
                let path = Self.headerPath(String(line.dropFirst(4)), prefix: "a/")
                current?.oldPath = path
                if path == nil { current?.kind = .added }
            } else if line.hasPrefix("+++ ") {
                let path = Self.headerPath(String(line.dropFirst(4)), prefix: "b/")
                current?.newPath = path
                if path == nil { current?.kind = .deleted }
            } else if line.hasPrefix("new file mode ") {
                current?.kind = .added
                current?.oldPath = nil
                current?.newMode = String(line.dropFirst("new file mode ".count))
            } else if line.hasPrefix("deleted file mode ") {
                current?.kind = .deleted
                current?.newPath = nil
                current?.oldMode = String(line.dropFirst("deleted file mode ".count))
            } else if line.hasPrefix("old mode ") {
                current?.oldMode = String(line.dropFirst("old mode ".count))
            } else if line.hasPrefix("new mode ") {
                current?.newMode = String(line.dropFirst("new mode ".count))
            } else if line.hasPrefix("rename from ") {
                current?.kind = .renamed
                current?.oldPath = GitPath.unquote(String(line.dropFirst("rename from ".count)))
            } else if line.hasPrefix("rename to ") {
                current?.kind = .renamed
                current?.newPath = GitPath.unquote(String(line.dropFirst("rename to ".count)))
            } else if line.hasPrefix("copy from ") {
                current?.kind = .copied
                current?.oldPath = GitPath.unquote(String(line.dropFirst("copy from ".count)))
            } else if line.hasPrefix("copy to ") {
                current?.kind = .copied
                current?.newPath = GitPath.unquote(String(line.dropFirst("copy to ".count)))
            } else if line.hasPrefix("similarity index ") {
                current?.similarity = Int(line.dropFirst("similarity index ".count).dropLast())
            } else if line.hasPrefix("index ") {
                // `index abc..def 100644` carries the mode when it did not change.
                let parts = line.split(separator: " ")
                if parts.count == 3, current?.oldMode == nil, current?.newMode == nil {
                    current?.oldMode = String(parts[2])
                    current?.newMode = String(parts[2])
                }
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                current?.isBinary = true
            }
        }

        /// Returns `false` when the line does not belong to the open hunk.
        mutating func consumeHunkLine(_ line: String) -> Bool {
            if line.hasPrefix("\\") {
                // `\ No newline at end of file` applies to the line right before it.
                if let last = hunk?.lines.indices.last { hunk?.lines[last].noNewlineAtEnd = true }
                return true
            }
            guard oldRemaining > 0 || newRemaining > 0 else { return false }

            let marker = line.first
            let text = String(line.dropFirst())
            switch marker {
            case "+":
                hunk?.lines.append(DiffLine(kind: .addition, text: text, oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
                newRemaining -= 1
            case "-":
                hunk?.lines.append(DiffLine(kind: .deletion, text: text, oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
                oldRemaining -= 1
            case " ", nil:
                // An empty line is a context line whose leading space was stripped by an editor.
                hunk?.lines.append(DiffLine(kind: .context, text: text, oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1
                newLine += 1
                oldRemaining -= 1
                newRemaining -= 1
            default:
                return false
            }
            return true
        }

        mutating func openHunk(_ line: String) {
            guard let header = Self.parseHunkHeader(line) else { return }
            hunk = header
            oldLine = header.oldStart
            newLine = header.newStart
            oldRemaining = header.oldCount
            newRemaining = header.newCount
        }

        mutating func closeHunk() {
            if let hunk { current?.hunks.append(hunk) }
            hunk = nil
            oldRemaining = 0
            newRemaining = 0
        }

        mutating func closeFile() {
            closeHunk()
            if let current { files.append(current) }
            current = nil
        }

        mutating func finish() -> [FileDiff] {
            closeFile()
            return files
        }

        static func parseHunkHeader(_ line: String) -> Hunk? {
            // @@ -oldStart[,oldCount] +newStart[,newCount] @@ section
            let body = line.dropFirst(3)
            guard let close = body.range(of: " @@") else { return nil }
            let ranges = body[..<close.lowerBound].split(separator: " ")
            guard ranges.count == 2,
                  let old = parseRange(ranges[0], sign: "-"),
                  let new = parseRange(ranges[1], sign: "+")
            else { return nil }
            var section = String(body[close.upperBound...])
            if section.hasPrefix(" ") { section.removeFirst() }
            return Hunk(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count, section: section)
        }

        static func parseRange(_ text: Substring, sign: Character) -> (start: Int, count: Int)? {
            guard text.first == sign else { return nil }
            let parts = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]) else { return nil }
            let count = parts.count > 1 ? Int(parts[1]) : 1
            guard let count else { return nil }
            return (start, count)
        }

        /// Parses `a/<old> b/<new>`. Ambiguous with spaces, so later `---`/`+++`/rename headers take precedence.
        static func fileFromGitHeader(_ rest: String) -> FileDiff {
            var file = FileDiff(oldPath: nil, newPath: nil, kind: .modified)
            if rest.hasPrefix("\"") {
                let (old, remainder) = GitPath.unquotePrefix(rest)
                file.oldPath = old.map { stripPrefix($0, "a/") }
                let trimmed = remainder.drop { $0 == " " }
                file.newPath = stripPrefix(GitPath.unquote(String(trimmed)), "b/")
            } else if let (old, new) = splitSymmetric(rest) {
                file.oldPath = old
                file.newPath = new
            } else if let range = rest.range(of: " b/") {
                file.oldPath = stripPrefix(String(rest[..<range.lowerBound]), "a/")
                file.newPath = GitPath.unquote(String(rest[range.upperBound...]))
            }
            return file
        }

        /// For `a/X b/X` both halves have the same length, which resolves paths containing ` b/`.
        static func splitSymmetric(_ rest: String) -> (String, String)? {
            let chars = Array(rest)
            guard chars.count % 2 == 1 else { return nil }
            let half = chars.count / 2
            guard chars[half] == " " else { return nil }
            let left = String(chars[..<half])
            let right = String(chars[(half + 1)...])
            guard left.hasPrefix("a/"), right.hasPrefix("b/"), left.dropFirst(2) == right.dropFirst(2) else { return nil }
            return (String(left.dropFirst(2)), String(right.dropFirst(2)))
        }

        static func headerPath(_ raw: String, prefix: String) -> String? {
            // Strip a trailing tab+timestamp that some tools append.
            var value = raw
            if !value.hasPrefix("\""), let tab = value.firstIndex(of: "\t") { value = String(value[..<tab]) }
            if value == "/dev/null" { return nil }
            return stripPrefix(GitPath.unquote(value), prefix)
        }

        static func stripPrefix(_ path: String, _ prefix: String) -> String {
            path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
    }
}

/// Helpers for git's C-style quoted paths (`"tab\there"`, octal UTF-8 escapes).
enum GitPath {
    static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\"") else { return value }
        return unquotePrefix(value).0 ?? value
    }

    /// Unquotes a leading quoted string and returns it with the rest of the input.
    static func unquotePrefix(_ value: String) -> (String?, Substring) {
        let bytes = Array(value.utf8)
        guard bytes.first == UInt8(ascii: "\"") else { return (nil, Substring(value)) }
        var out: [UInt8] = []
        var index = 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let rest = String(decoding: bytes[(index + 1)...], as: UTF8.self)
                return (String(decoding: out, as: UTF8.self), Substring(rest))
            }
            if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                index += 1
                let escaped = bytes[index]
                switch escaped {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "a"): out.append(0x07)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "v"): out.append(0x0B)
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var octal = 0
                    var digits = 0
                    while digits < 3, index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[index]) {
                        octal = octal * 8 + Int(bytes[index] - UInt8(ascii: "0"))
                        index += 1
                        digits += 1
                    }
                    out.append(UInt8(truncatingIfNeeded: octal))
                    continue
                default: out.append(escaped)
                }
            } else {
                out.append(byte)
            }
            index += 1
        }
        return (nil, Substring(value))
    }
}

extension Data {
    /// Splits on `\n` only, keeping `\r` as content, and drops the empty tail after a final newline.
    func lines() -> [Data] {
        var result = split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
        if result.last?.isEmpty == true { result.removeLast() }
        return result
    }
}
