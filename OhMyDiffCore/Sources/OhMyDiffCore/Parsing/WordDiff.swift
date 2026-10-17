/// Word-level highlighting for lines that replace each other.
///
/// Within a hunk, each run of deletions directly followed by a run of additions is paired line by line
/// (first with first, and so on). Each pair is tokenized into words, whitespace runs and single
/// punctuation characters, and the tokens outside their longest common subsequence are marked as changed.
public enum WordDiff {
    /// Character ranges (offsets into `DiffLine.text`) that changed, keyed by the line's index in `hunk.lines`.
    /// Lines without an entry have no word-level highlighting.
    public static func highlights(for hunk: Hunk) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        let lines = hunk.lines
        var index = 0

        while index < lines.count {
            guard lines[index].kind == .deletion else {
                index += 1
                continue
            }
            let deletionStart = index
            while index < lines.count, lines[index].kind == .deletion { index += 1 }
            let additionStart = index
            while index < lines.count, lines[index].kind == .addition { index += 1 }

            let pairs = min(additionStart - deletionStart, index - additionStart)
            for offset in 0..<pairs {
                let old = deletionStart + offset
                let new = additionStart + offset
                guard let (oldRanges, newRanges) = changedRanges(lines[old].text, lines[new].text) else { continue }
                result[old] = oldRanges
                result[new] = newRanges
            }
        }
        return result
    }

    /// Lines with more tokens than this are not compared, which bounds the quadratic LCS.
    static let tokenLimit = 400
    /// Below this share of unchanged characters the lines are treated as unrelated, so highlighting
    /// whole lines in confetti-like fragments is avoided.
    static let minimumSimilarity = 0.4

    /// Changed ranges in `old` and `new`, or `nil` when the lines are identical, too long or too different.
    static func changedRanges(_ old: String, _ new: String) -> ([Range<Int>], [Range<Int>])? {
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        guard oldTokens.count <= tokenLimit, newTokens.count <= tokenLimit, old != new else { return nil }

        let (oldKept, newKept) = commonTokens(oldTokens.map(\.text), newTokens.map(\.text))
        let keptLength = oldKept.indices.filter { oldKept[$0] }.reduce(0) { $0 + oldTokens[$1].range.count }
        let total = max(old.count, new.count)
        guard total > 0, Double(keptLength) / Double(total) >= minimumSimilarity else { return nil }

        return (ranges(oldTokens, kept: oldKept), ranges(newTokens, kept: newKept))
    }

    struct Token {
        var text: Substring
        var range: Range<Int>
    }

    static func tokenize(_ text: String) -> [Token] {
        enum Class { case word, space, other }
        func classify(_ character: Character) -> Class {
            if character.isLetter || character.isNumber || character == "_" { return .word }
            if character.isWhitespace { return .space }
            return .other
        }

        var tokens: [Token] = []
        var start = text.startIndex
        var startOffset = 0
        var offset = 0
        var current: Class?

        for index in text.indices {
            let kind = classify(text[index])
            // Punctuation never merges, so `foo(bar)` → `foo`, `(`, `bar`, `)`.
            if let current, current != kind || kind == .other {
                tokens.append(Token(text: text[start..<index], range: startOffset..<offset))
                start = index
                startOffset = offset
            }
            current = kind
            offset += 1
        }
        if current != nil {
            tokens.append(Token(text: text[start...], range: startOffset..<offset))
        }
        return tokens
    }

    /// Marks the tokens of each side that belong to a longest common subsequence.
    static func commonTokens(_ old: [Substring], _ new: [Substring]) -> ([Bool], [Bool]) {
        let n = old.count, m = new.count
        // lengths[i][j] = LCS length of old[i...] and new[j...], flattened.
        var lengths = [Int](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i * (m + 1) + j] = old[i] == new[j]
                    ? lengths[(i + 1) * (m + 1) + j + 1] + 1
                    : max(lengths[(i + 1) * (m + 1) + j], lengths[i * (m + 1) + j + 1])
            }
        }

        var oldKept = [Bool](repeating: false, count: n)
        var newKept = [Bool](repeating: false, count: m)
        var i = 0, j = 0
        while i < n, j < m {
            if old[i] == new[j] {
                oldKept[i] = true
                newKept[j] = true
                i += 1
                j += 1
            } else if lengths[(i + 1) * (m + 1) + j] >= lengths[i * (m + 1) + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (oldKept, newKept)
    }

    /// Merges adjacent changed tokens into ranges.
    private static func ranges(_ tokens: [Token], kept: [Bool]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for (token, isKept) in zip(tokens, kept) where !isKept {
            if let last = result.last, last.upperBound == token.range.lowerBound {
                result[result.count - 1] = last.lowerBound..<token.range.upperBound
            } else {
                result.append(token.range)
            }
        }
        return result
    }
}
