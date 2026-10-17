import Foundation

/// Parses `git diff --numstat -z` into line counts keyed by the post-change path.
///
/// Binary files report `-` for both counts and are left out.
public enum NumstatParser {
    public static func parse(_ data: Data) -> [String: LineStats] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result: [String: LineStats] = [:]
        var index = 0

        while index < tokens.count {
            let fields = tokens[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            index += 1
            guard fields.count == 3 else { continue }

            let path: String
            if fields[2].isEmpty {
                // Renames and copies: the old and new paths follow as separate NUL-terminated tokens.
                guard index + 1 < tokens.count else { break }
                path = tokens[index + 1]
                index += 2
            } else {
                path = String(fields[2])
            }
            guard let additions = Int(fields[0]), let deletions = Int(fields[1]) else { continue }
            result[path] = LineStats(additions: additions, deletions: deletions)
        }
        return result
    }
}
