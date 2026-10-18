import Foundation

/// A `but` release number such as 0.22.3.
public struct ButVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var components: [Int]

    public init(_ components: [Int]) {
        self.components = components
    }

    /// Reads the first dotted number, e.g. from `but 0.22.3` or `0.23.0-nightly.4`.
    public init?(_ string: String) {
        guard let match = string.firstMatch(of: #/\d+(?:\.\d+)+/#) else { return nil }
        components = match.output.split(separator: ".").compactMap { Int($0) }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

/// Why a GitButler workspace is shown as a plain git repository instead.
public struct ButIncompatibility: Sendable, Hashable, CustomStringConvertible {
    /// `nil` when `but --version` printed nothing recognizable.
    public var version: ButVersion?
    public var violations: [String]

    public init(version: ButVersion?, violations: [String]) {
        self.version = version
        self.violations = violations
    }

    public var description: String {
        "GitButler \(version?.description ?? "(unknown version)") is not yet supported, showing plain git view"
    }
}

/// Guards against `but` releases whose JSON ohmydiff would misread.
public enum ButCompatibility {
    /// The newest `but` release the contract tests passed against, from `gitbutler.json` next to this file.
    public static let knownGood: ButVersion? = {
        struct Record: Decodable { var knownGood: String }
        guard let url = Bundle.module.url(forResource: "gitbutler", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }
        return ButVersion(record.knownGood)
    }()

    /// The installed release, from `but --version`.
    public static func version(of toolchain: Toolchain) async -> ButVersion? {
        guard let but = toolchain.but,
              let output = try? await toolchain.runner.run(
                  but, arguments: ["--version"], environment: toolchain.environment, timeout: .seconds(10)),
              output.exitCode == 0
        else { return nil }
        return ButVersion(output.stdoutString)
    }

    /// Releases up to the known-good one are trusted; any other release, or an unknown one, must
    /// produce `status` output that passes the contract.
    public static func check(status: Data, version: ButVersion?, knownGood: ButVersion? = knownGood) -> ButIncompatibility? {
        if let version, let knownGood, version <= knownGood { return nil }
        let violations = ButContract.violations(in: status)
        return violations.isEmpty ? nil : ButIncompatibility(version: version, violations: violations)
    }
}
