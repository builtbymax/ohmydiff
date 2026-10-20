import AppKit
import Observation
import OhMyDiffCore
import Sparkle

/// Sparkle updates, shown in the main window's update bar and in Settings instead of Sparkle's own windows.
///
/// Only runs in Release builds whose Info.plist has a feed URL and an EdDSA public key, so Debug builds from
/// Xcode never offer to replace themselves.
@MainActor @Observable
final class Updater: NSObject {
    static let shared = Updater()

    /// A release newer than this build.
    struct Update: Equatable {
        var version: String
        /// The embedded release notes, if the appcast has Markdown or plain text ones.
        var notes: AttributedString?
        var notesURL: URL?
        /// Information only: there is nothing to install, the button opens `notesURL`.
        var isInformational = false
    }

    enum Phase: Equatable {
        case idle
        /// A check the user started, from the menu, the command palette or Settings.
        case checking
        case available(Update)
        /// `progress` is `nil` until the size of the download is known.
        case downloading(Update, progress: Double?)
        case extracting(Update, progress: Double)
        /// Downloaded and verified; installs when the user restarts, or on quit.
        case ready(Update)
        case installing(Update)
        /// After a check the user started found nothing. Clears itself.
        case upToDate
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var lastCheck: Date?
    /// Off in Debug builds and in builds without a feed.
    var isAvailable: Bool { updater != nil }

    var automaticallyChecks = false {
        didSet { if updater?.automaticallyChecksForUpdates != automaticallyChecks { updater?.automaticallyChecksForUpdates = automaticallyChecks } }
    }

    var automaticallyDownloads = false {
        didSet { if updater?.automaticallyDownloadsUpdates != automaticallyDownloads { updater?.automaticallyDownloadsUpdates = automaticallyDownloads } }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    @ObservationIgnored private var updater: SPUUpdater?
    /// Sparkle's pending question: install, skip or dismiss the update found, or relaunch into the downloaded one.
    @ObservationIgnored private var reply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    /// Set for an update downloaded in the background: installs it and relaunches at once.
    @ObservationIgnored private var installNow: (() -> Void)?
    /// The user already asked to install, so the download ends in a relaunch without asking again.
    @ObservationIgnored private var relaunchWhenReady = false
    @ObservationIgnored private var expectedLength: UInt64 = 0
    @ObservationIgnored private var receivedLength: UInt64 = 0
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    func start() {
        #if DEBUG
        return
        #else
        let info = Bundle.main.infoDictionary ?? [:]
        guard updater == nil,
              let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        self.updater = updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        lastCheck = updater.lastUpdateCheckDate
        #endif
    }

    /// Whether Check for Updates… can run now: not while Sparkle is already busy with an update.
    var canCheck: Bool {
        guard isAvailable else { return false }
        switch phase {
        case .idle, .upToDate, .failed: return true
        default: return false
        }
    }

    func checkForUpdates() {
        guard let updater, canCheck else { return }
        clearTask?.cancel()
        updater.checkForUpdates()
    }

    /// Downloads and installs the update found, or relaunches into the one already downloaded.
    func install() {
        switch phase {
        case .available(let update) where update.isInformational:
            if let url = update.notesURL { NSWorkspace.shared.open(url) }
            answer(.dismiss)
        case .available:
            relaunchWhenReady = true
            answer(.install)
        case .ready(let update):
            if let installNow {
                self.installNow = nil
                phase = .installing(update)
                installNow()
            } else {
                phase = .installing(update)
                answer(.install)
            }
        default:
            break
        }
    }

    /// Skips this version: scheduled checks stay quiet until a newer one is out.
    func skip() {
        answer(.skip)
    }

    /// Hides the bar until the next scheduled check. A downloaded update still installs on quit.
    func dismiss() {
        switch phase {
        case .available, .ready:
            if reply != nil { answer(.dismiss) } else { phase = .idle }
        case .checking, .downloading, .extracting:
            cancellation?()
            cancellation = nil
            phase = .idle
        case .upToDate, .failed:
            phase = .idle
        case .idle, .installing:
            break
        }
    }

    private func answer(_ choice: SPUUserUpdateChoice) {
        let reply = self.reply
        self.reply = nil
        if choice != .install { phase = .idle }
        reply?(choice)
    }

    private func clear(after delay: Duration) {
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if phase == .upToDate { phase = .idle }
        }
    }

    /// The update the current phase is about, kept from the update found through download and install.
    private var currentUpdate: Update? {
        switch phase {
        case .available(let update), .downloading(let update, _), .extracting(let update, _), .ready(let update), .installing(let update):
            update
        case .idle, .checking, .upToDate, .failed:
            nil
        }
    }

    private static func update(for item: SUAppcastItem) -> Update {
        var notes: AttributedString?
        if let description = item.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            switch item.itemDescriptionFormat {
            case "markdown":
                notes = try? AttributedString(markdown: ReleaseNotes.summary(description), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            case "plain-text":
                notes = AttributedString(description)
            default:
                // HTML notes are left to the link.
                break
            }
        }
        return Update(
            version: item.displayVersionString,
            notes: notes,
            notesURL: item.fullReleaseNotesURL ?? item.releaseNotesURL ?? item.infoURL,
            isInformational: item.isInformationOnlyUpdate)
    }
}

// MARK: - SPUUserDriver

extension Updater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist turns automatic checks on, so Sparkle has nothing to ask; Settings can turn them off.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        phase = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        self.reply = reply
        lastCheck = updater?.lastUpdateCheckDate ?? Date()
        let update = Self.update(for: appcastItem)
        switch state.stage {
        case .notDownloaded: phase = .available(update)
        case .downloaded: phase = .ready(update)
        case .installing: phase = .installing(update)
        @unknown default: phase = .available(update)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Release notes are embedded in the appcast, so Sparkle has none to download.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        lastCheck = updater?.lastUpdateCheckDate ?? Date()
        phase = .upToDate
        clear(after: .seconds(4))
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        reply = nil
        relaunchWhenReady = false
        phase = .failed(error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expectedLength = 0
        receivedLength = 0
        if let update = currentUpdate { phase = .downloading(update, progress: nil) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard let update = currentUpdate, expectedLength > 0 else { return }
        phase = .downloading(update, progress: min(1, Double(receivedLength) / Double(expectedLength)))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        if let update = currentUpdate { phase = .extracting(update, progress: 0) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if let update = currentUpdate { phase = .extracting(update, progress: progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let update = currentUpdate else { return reply(.dismiss) }
        if relaunchWhenReady {
            relaunchWhenReady = false
            phase = .installing(update)
            reply(.install)
        } else {
            self.reply = reply
            phase = .ready(update)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if let update = currentUpdate { phase = .installing(update) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        phase = .idle
        acknowledgement()
    }

    func showUpdateInFocus() {
        NSApp.activate()
    }

    func dismissUpdateInstallation() {
        cancellation = nil
        reply = nil
        relaunchWhenReady = false
        // An update downloaded in the background stays offered until it installs on quit.
        switch phase {
        case .upToDate, .failed: break
        case .ready where installNow != nil: break
        default: phase = .idle
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension Updater: SPUUpdaterDelegate {
    /// With automatic downloads, Sparkle installs a downloaded update on quit without asking; the bar
    /// offers to restart into it now.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        phase = .ready(Self.update(for: item))
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheck = updater.lastUpdateCheckDate
    }
}
