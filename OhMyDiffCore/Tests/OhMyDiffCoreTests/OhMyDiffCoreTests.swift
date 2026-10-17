import Testing
@testable import OhMyDiffCore

@Test func versionIsSet() {
    #expect(!OhMyDiffCore.version.isEmpty)
}
