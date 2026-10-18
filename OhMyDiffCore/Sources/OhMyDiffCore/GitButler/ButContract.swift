import Foundation

/// A strict check of `but --json status` output against the fields ohmydiff reads.
///
/// `ButStatus` decodes leniently, so a renamed or retyped field would quietly turn into empty or
/// wrong data. This finds those instead. Extra fields are fine; missing, mistyped or unknown values are not.
public enum ButContract {
    /// Each problem once, as `<path>: <problem>` with array indices collapsed, e.g.
    /// `stacks[].branches[].branchStatus: unknown value "pending"`. Empty when the output conforms.
    public static func violations(in data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return ["$: not valid JSON"]
        }
        var checker = Checker()
        checker.status(json)
        return checker.problems
    }

    private struct Checker {
        private(set) var problems: [String] = []
        private var seen: Set<String> = []

        mutating func status(_ value: Any) {
            guard let object = self.object(value, at: "$") else { return }
            array(object, "uncommittedChanges", at: "$") { $0.change($1, at: $2) }
            array(object, "stacks", at: "$") { $0.stack($1, at: $2) }
            if let mergeBase = field(object, "mergeBase", at: "$") { commit(mergeBase, at: "mergeBase") }
            if let upstream = object["upstreamState"], !(upstream is NSNull),
               let state = self.object(upstream, at: "upstreamState") {
                int(state, "behind", at: "upstreamState")
            }
        }

        mutating func stack(_ value: Any, at path: String) {
            guard let object = self.object(value, at: path) else { return }
            string(object, "cliId", at: path)
            array(object, "assignedChanges", at: path) { $0.change($1, at: $2) }
            array(object, "branches", at: path) { $0.branch($1, at: $2) }
        }

        mutating func branch(_ value: Any, at path: String) {
            guard let object = self.object(value, at: path) else { return }
            string(object, "name", at: path, nonEmpty: true)
            array(object, "commits", at: path) { $0.commit($1, at: $2) }
            array(object, "upstreamCommits", at: path) { $0.commit($1, at: $2) }
            if let status = string(object, "branchStatus", at: path), HistoryBranch.Status(butStatus: status) == nil {
                report("\(path).branchStatus", "unknown value \"\(status)\"")
            }
        }

        mutating func commit(_ value: Any, at path: String) {
            guard let object = self.object(value, at: path) else { return }
            if let id = string(object, "commitId", at: path),
               !(id.count == 40 || id.count == 64) || !id.allSatisfy(\.isHexDigit) {
                report("\(path).commitId", "not a commit hash")
            }
            string(object, "message", at: path)
            string(object, "authorName", at: path)
            string(object, "authorEmail", at: path)
            if let date = string(object, "createdAt", at: path), ButDate.parse(date) == nil {
                report("\(path).createdAt", "unparseable date \"\(date)\"")
            }
            // `null` on commits that are not part of a branch, such as the merge base.
            if let conflicted = field(object, "conflicted", at: path), !(conflicted is NSNull), !isBool(conflicted) {
                report("\(path).conflicted", "expected a boolean or null")
            }
            if let changes = object["changes"], !(changes is NSNull) {
                elements(changes, at: "\(path).changes") { $0.change($1, at: $2) }
            }
        }

        mutating func change(_ value: Any, at path: String) {
            guard let object = self.object(value, at: path) else { return }
            string(object, "cliId", at: path)
            string(object, "filePath", at: path, nonEmpty: true)
            if let type = string(object, "changeType", at: path),
               ButChange(filePath: "", changeType: type).kind == .unknown {
                report("\(path).changeType", "unknown value \"\(type)\"")
            }
        }

        // MARK: - Primitives

        private func join(_ path: String, _ key: String) -> String {
            path == "$" ? key : "\(path).\(key)"
        }

        private mutating func report(_ path: String, _ problem: String) {
            let line = "\(path): \(problem)"
            if seen.insert(line).inserted { problems.append(line) }
        }

        private mutating func object(_ value: Any, at path: String) -> [String: Any]? {
            guard let object = value as? [String: Any] else {
                report(path, "expected an object")
                return nil
            }
            return object
        }

        private mutating func field(_ object: [String: Any], _ key: String, at path: String) -> Any? {
            guard let value = object[key] else {
                report(join(path, key), "missing")
                return nil
            }
            return value
        }

        @discardableResult
        private mutating func string(_ object: [String: Any], _ key: String, at path: String, nonEmpty: Bool = false) -> String? {
            guard let value = field(object, key, at: path) else { return nil }
            guard let string = value as? String else {
                report(join(path, key), "expected a string")
                return nil
            }
            if nonEmpty, string.isEmpty { report(join(path, key), "empty") }
            return string
        }

        private mutating func int(_ object: [String: Any], _ key: String, at path: String) {
            guard let value = field(object, key, at: path) else { return }
            if isBool(value) || !(value is NSNumber) { report(join(path, key), "expected a number") }
        }

        private mutating func array(
            _ object: [String: Any], _ key: String, at path: String,
            _ element: (inout Checker, Any, String) -> Void
        ) {
            guard let value = field(object, key, at: path) else { return }
            elements(value, at: join(path, key), element)
        }

        private mutating func elements(_ value: Any, at path: String, _ element: (inout Checker, Any, String) -> Void) {
            guard let items = value as? [Any] else {
                report(path, "expected an array")
                return
            }
            for item in items { element(&self, item, "\(path)[]") }
        }

        /// `JSONSerialization` hands booleans back as `NSNumber`; only the boolean singletons count.
        private func isBool(_ value: Any) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
    }
}
