/// Case-insensitive subsequence matching with a score that favours prefixes, word starts and runs.
public enum FuzzyMatcher {
    public struct Match: Sendable, Hashable {
        public var score: Int
        /// Offsets (in `Character`s) of the matched characters in the candidate.
        public var indices: [Int]
    }

    /// Returns `nil` when `query` is not a subsequence of `candidate`. An empty query matches everything with score 0.
    public static func match(_ query: String, in candidate: String) -> Match? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, indices: []) }
        let haystack = Array(candidate)
        let lowered = haystack.map { Character($0.lowercased()) }
        guard needle.count <= haystack.count else { return nil }

        // Greedy left-to-right, but jump ahead to a word start when one is available for the same character.
        var indices: [Int] = []
        var position = 0
        for character in needle {
            guard let next = (position..<lowered.count).first(where: { lowered[$0] == character }) else { return nil }
            let boundary = (next..<lowered.count).first { lowered[$0] == character && isWordStart(haystack, $0) }
            let chosen = (indices.last.map { next == $0 + 1 } ?? false) ? next : (boundary ?? next)
            // Only take the boundary if the rest of the needle still fits after it.
            if chosen != next, !fits(needle, from: indices.count + 1, in: lowered, after: chosen) {
                indices.append(next)
                position = next + 1
            } else {
                indices.append(chosen)
                position = chosen + 1
            }
        }

        var score = 0
        for (offset, index) in indices.enumerated() {
            score += 1
            if isWordStart(haystack, index) { score += 8 }
            if offset > 0 {
                let gap = index - indices[offset - 1] - 1
                score += gap == 0 ? 5 : -min(gap, 5)
            }
        }
        if indices.first == 0 { score += 10 }
        if needle.count == haystack.count { score += 10 }
        score -= max(0, haystack.count - needle.count) / 4
        return Match(score: score, indices: indices)
    }

    /// Filters and sorts `items` by match score, keeping the original order for ties.
    public static func rank<T>(_ items: [T], query: String, key: (T) -> String) -> [(item: T, match: Match)] {
        items.enumerated()
            .compactMap { offset, item in match(query, in: key(item)).map { (offset, item, $0) } }
            .sorted { $0.2.score != $1.2.score ? $0.2.score > $1.2.score : $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }

    private static func isWordStart(_ characters: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        let current = characters[index]
        if "/-_. ".contains(previous) { return true }
        return previous.isLowercase && current.isUppercase
    }

    private static func fits(_ needle: [Character], from start: Int, in haystack: [Character], after index: Int) -> Bool {
        var position = index + 1
        for character in needle[start...] {
            guard let next = (position..<haystack.count).first(where: { haystack[$0] == character }) else { return false }
            position = next + 1
        }
        return true
    }
}
