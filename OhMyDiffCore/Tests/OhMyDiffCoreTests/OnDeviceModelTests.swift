import Foundation
import Testing
@testable import OhMyDiffCore

@Suite struct OnDeviceModelTests {
    @Test func makesBranchNamesFromAnyCase() {
        #expect(OnDeviceModel.branchName(type: "feat", words: "DarkModeToggle") == "feat/dark-mode-toggle")
        #expect(OnDeviceModel.branchName(type: "fix", words: "Fix Return Value") == "fix/return-value")
        #expect(OnDeviceModel.branchName(type: "chore", words: "Chore Fix: Return Items") == "chore/fix-return-items")
        #expect(OnDeviceModel.branchName(type: "feat", words: "hal-128 ai suggestions for everything we do") == "feat/hal-128-ai-suggestions-for")
        #expect(OnDeviceModel.branchName(type: "fix", words: "") == nil)
        #expect(OnDeviceModel.branchName(type: "fix", words: "émoji 🎉") == "fix/moji")
    }

    @Test func gistListsFilesAndFitsTheBudget() {
        let diff = "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n" + String(repeating: "+x\n", count: 5000)
        let gist = OnDeviceModel.gist(of: diff, characters: 1000)
        #expect(gist.hasPrefix("Files: a.swift\n\n"))
        #expect(gist.utf8.count < 1100)
        #expect(gist.hasSuffix("left out]"))
        #expect(OnDeviceModel.gist(of: "+++ b/x\n+y", characters: 1000).hasSuffix("+y"))
    }

    @Test func estimatesTokensConservatively() {
        #expect(OnDeviceModel.estimatedTokens("") == 0)
        #expect(OnDeviceModel.estimatedTokens("abc") == 1)
        #expect(OnDeviceModel.estimatedTokens(String(repeating: "x", count: 3000)) == 1000)
    }

    @Test func formatsCommitMessagesInEachStyle() {
        let parts = CommitParts(type: "Feat", scope: "Settings View", title: "Added a dark mode toggle.", bullets: ["Add the toggle.", " ", "URL stays"])
        #expect(parts.formatted(style: .conventional, titleLimit: 72, ticket: nil, ticketInTitle: false)
            == "feat(settings-view): added a dark mode toggle\n\n- add the toggle\n- URL stays")
        #expect(parts.formatted(style: .gitmoji, titleLimit: 72, ticket: "HAL-1", ticketInTitle: true).hasPrefix("✨ added a dark mode toggle (HAL-1)\n"))
        #expect(parts.formatted(style: .free, titleLimit: 72, ticket: "HAL-1", ticketInTitle: false).hasSuffix("\n\nRefs: HAL-1"))
        #expect(parts.formatted(style: .free, titleLimit: 72, ticket: nil, ticketInTitle: false).hasPrefix("Added a dark mode toggle\n"))
        let short = parts.formatted(style: .conventional, titleLimit: 30, ticket: nil, ticketInTitle: false)
        #expect(short.prefix { $0 != "\n" } == "feat(settings-view): added a")
    }

    @Test func explainsWhyChangesAreTooLarge() {
        let failure = OnDeviceModel.Failure.tooLarge(tokens: 9000, limit: 3496)
        #expect(failure.description.contains("too large for on-device"))
        #expect(failure.description.contains("Settings → AI"))
    }

    /// Runs the real model; `OHMYDIFF_LIVE_AI=1 swift test --filter OnDeviceModelTests` on a Mac with Apple Intelligence.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OHMYDIFF_LIVE_AI"] == "1"))
    func liveBranchNamesAndCommitMessage() async throws {
        let diff = "--- a/List.swift\n+++ b/List.swift\n@@ -1,2 +1,3 @@\n func first() -> Item? {\n+    if items.isEmpty { return nil }\n     return items[0]\n"
        let start = ContinuousClock.now
        let names = try await OnDeviceModel.branchNames(context: TemplateContext(diff: diff))
        print("on-device branch names", names, ContinuousClock.now - start)
        #expect(!names.isEmpty)
        #expect(names.allSatisfy { Suggester.branchName(from: $0) == $0 && $0.contains("/") })

        let message = try await OnDeviceModel.commitMessage(context: TemplateContext(diff: diff), style: .conventional)
        print("on-device commit message", message)
        #expect(!message.isEmpty)

        let huge = TemplateContext(diff: String(repeating: "+let x = 1\n", count: 3000))
        await #expect(throws: OnDeviceModel.Failure.self) { try await OnDeviceModel.commitMessage(context: huge, style: .conventional) }
    }
}
