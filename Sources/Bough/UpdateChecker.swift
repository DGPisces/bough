import AppKit
import Combine
import Sparkle
import os.log

/// Simplified update state surfaced to the About page. Sparkle handles the
/// actual download / install UX itself — we only mirror enough state to drive
/// the little banner at the bottom of the About page.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case failed(String)
}

@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()
    private static let log = Logger(subsystem: "com.dgpisces.bough", category: "UpdateChecker")
    nonisolated private static let sparkleNoUpdateErrorCode = 1001
    nonisolated private static let fallbackAppcastFeedURLString =
        "https://raw.githubusercontent.com/DGPisces/bough/appcast/appcast.xml"
    nonisolated private static let defaultHomebrewPrefixes = ["/opt/homebrew", "/usr/local"]

    @Published private(set) var state: UpdateState = .idle

    /// Tracks whether controller.startUpdater() has been called. Calling it a
    /// second time on an already-started SPUStandardUpdaterController is
    /// undefined behavior in Sparkle and may cause double-checks or crashes.
    private var updaterStarted = false

    private lazy var controller: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private override init() {
        super.init()
        Self.clearDeprecatedUpdateChannelSelection()
    }

    nonisolated static func appcastFeedURLString(
        bundleInfo: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        bundleInfo?["SUFeedURL"] as? String ?? fallbackAppcastFeedURLString
    }

    nonisolated static func clearDeprecatedUpdateChannelSelection(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: SettingsKey.deprecatedUpdateChannel)
    }

    #if DEBUG
    nonisolated static func shouldSkipSparkleForDebugLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bundlePath: String = Bundle.main.bundlePath,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        arguments.contains("--preview")
            || bundlePath.contains("Bough-Debug.app")
            || bundleIdentifier == nil
    }
    #endif

    /// Exposed for advanced integrations (menu bindings etc.); prefer
    /// `checkForUpdates()` and `state` for most UI.
    var updater: SPUUpdater { controller.updater }

    /// True when the app bundle lives inside a Homebrew cask path. Homebrew
    /// manages its own upgrade flow, so Sparkle stays hands-off in that case.
    var isHomebrewInstall: Bool {
        Self.isHomebrewInstall(
            bundlePath: Bundle.main.bundlePath,
            resolvedBundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            bundleShortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }

    nonisolated static func isHomebrewInstall(
        bundlePath: String,
        resolvedBundlePath: String? = nil,
        bundleShortVersion: String? = nil,
        homebrewPrefixes: [String] = defaultHomebrewPrefixes,
        fileManager: FileManager = .default
    ) -> Bool {
        let candidatePaths = [bundlePath, resolvedBundlePath]
            .compactMap { $0 }
            .map { comparablePath($0) }

        if candidatePaths.contains(where: isHomebrewCaskBundlePath) {
            return true
        }

        guard let bundleShortVersion, !bundleShortVersion.isEmpty else {
            return false
        }

        return homebrewPrefixes.contains { prefix in
            let caskBundlePath = "\(prefix)/Caskroom/bough/\(bundleShortVersion)/Bough.app"
            guard fileManager.fileExists(atPath: caskBundlePath) else {
                return false
            }
            let resolvedCaskBundlePath = comparablePath(
                URL(fileURLWithPath: caskBundlePath)
                    .resolvingSymlinksInPath()
                    .path
            )
            return candidatePaths.contains(resolvedCaskBundlePath)
        }
    }

    nonisolated static func shouldStartSparkleForInstall(
        bundlePath: String,
        resolvedBundlePath: String? = nil,
        bundleShortVersion: String? = nil,
        homebrewPrefixes: [String] = defaultHomebrewPrefixes
    ) -> Bool {
        !isHomebrewInstall(
            bundlePath: bundlePath,
            resolvedBundlePath: resolvedBundlePath,
            bundleShortVersion: bundleShortVersion,
            homebrewPrefixes: homebrewPrefixes
        )
    }

    nonisolated private static func isHomebrewCaskBundlePath(_ path: String) -> Bool {
        path.contains("/caskroom/bough/")
    }

    nonisolated private static func comparablePath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
            .lowercased()
    }

    // MARK: - Lifecycle

    /// Wire up Sparkle. Call once from `AppDelegate.applicationDidFinishLaunching`.
    func start() {
        guard !updaterStarted else { return }

        #if DEBUG
        if Self.shouldSkipSparkleForDebugLaunch() {
            Self.log.info("DEBUG preview launch detected — skipping Sparkle")
            return
        }
        #endif

        if !Self.shouldStartSparkleForInstall(
            bundlePath: Bundle.main.bundlePath,
            resolvedBundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            bundleShortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        ) {
            Self.log.info("Homebrew install detected — skipping Sparkle startup")
            updaterStarted = true
            return
        }

        // Do NOT set automaticallyChecksForUpdates here. Sparkle persists this
        // to UserDefaults (SUEnableAutomaticChecks) when the user toggles it in
        // Settings → About. Unconditionally setting it true on every launch
        // overwrites the stored preference, making the opt-out toggle non-functional.
        // On first launch (key absent), Sparkle falls back to the Info.plist default
        // (SUEnableAutomaticChecks = true), so auto-checks are still on by default.
        updaterStarted = true
        controller.startUpdater()
    }

    // MARK: - Public API (mirrors the pre-Sparkle signature for call-site compat)

    /// User-initiated check. Sparkle presents its own progress / prompt UI.
    func checkForUpdates() {
        guard !isHomebrewInstall else {
            Self.log.info("Homebrew install detected — ignoring Sparkle check request")
            return
        }
        guard updater.canCheckForUpdates else { return }
        state = .checking
        controller.checkForUpdates(nil)
    }

    /// Legacy entry point kept so existing call sites continue to compile.
    /// Sparkle drives the install flow from the `didFindValidUpdate` alert, so
    /// this just re-surfaces that alert if the user dismissed it.
    func performUpdate() {
        checkForUpdates()
    }

    nonisolated static func stateForAbortedUpdate(error: Error) -> UpdateState {
        let nsError = error as NSError
        // Sparkle SUErrors.h: SUNoUpdateError = 1001 means "No new update was found."
        if nsError.code == sparkleNoUpdateErrorCode {
            return .upToDate
        }
        return .failed(error.localizedDescription)
    }
}

// MARK: - UpdateState Helpers

extension UpdateState {
    /// True only when a newer version is available on the appcast.
    /// Used by the About sidebar badge (UI-SPEC.md — Component 2).
    var isUpdateAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateChecker: SPUUpdaterDelegate {
    // Sparkle dispatches delegate callbacks on an arbitrary queue; hop back
    // onto the main actor before touching @Published state.

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.state = .available(version: version)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.state = .upToDate
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let state = Self.stateForAbortedUpdate(error: error)
        Task { @MainActor in
            // Elevate to error level so background failures surface in logs.
            // Always update state — both user-initiated checks (state == .checking)
            // and background scheduled checks (state == .idle/.upToDate/.available)
            // should surface failures. Silent-drop on background auth/network errors
            // means the UI shows a green dot while updates cannot be fetched.
            switch state {
            case .upToDate:
                Self.log.info("Sparkle completed with no update available")
            case .failed(let description):
                Self.log.error("Sparkle aborted: \(description)")
            default:
                break
            }
            self.state = state
        }
    }
}
