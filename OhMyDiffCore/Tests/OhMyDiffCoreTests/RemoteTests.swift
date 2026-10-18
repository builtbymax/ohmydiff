import Foundation
import Testing
@testable import OhMyDiffCore

struct RemoteTests {
    @Test(arguments: [
        ("git@github.com:owner/repo.git", "https://github.com/owner/repo"),
        ("https://github.com/owner/repo.git", "https://github.com/owner/repo"),
        ("https://user@github.com/owner/repo", "https://github.com/owner/repo"),
        ("ssh://git@gitlab.com:2222/group/sub/repo.git", "https://gitlab.com/group/sub/repo"),
    ])
    func webURL(remote: String, expected: String) {
        #expect(Repository.webURL(forRemote: remote)?.absoluteString == expected)
    }

    @Test(arguments: ["/tmp/remote.git", "file:///tmp/remote.git", ""])
    func localRemotesHaveNoWebPage(remote: String) {
        #expect(Repository.webURL(forRemote: remote) == nil)
    }
}
