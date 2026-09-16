import AppKit
import Sparkle

/// Bridges Sparkle's updater to the panel UI. Scheduled checks run in the
/// background (SUEnableAutomaticChecks in Info.plist, daily by default); a
/// found update surfaces as the panel's Update row via the gentle-reminders
/// delegate instead of a focus-stealing alert, which matters for a
/// menu-bar-only (LSUIElement) app. Clicking the row hands off to Sparkle's
/// standard download/install/relaunch UI.
@MainActor
final class UpdateService: NSObject, ObservableObject {
    static let shared = UpdateService()

    // Current app bundle version (CFBundleShortVersionString)
    let currentVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()

    @Published var hasUpdate: Bool = false
    @Published var latestVersion: String? = nil

    // lazy so `self` can be the user-driver delegate; touched in init so the
    // updater (and its check scheduler) starts at launch, not on first access.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)

    private override init() {
        super.init()
        _ = updaterController
    }

    // MARK: - Install

    /// Update-row action: a user-initiated check brings up Sparkle's update UI
    /// and runs the download/install/relaunch flow. The panel is a
    /// non-activating NSPanel, so the app isn't active when the row is
    /// clicked; without an explicit activate, macOS 14's cooperative
    /// activation leaves Sparkle's window behind the frontmost app.
    func installUpdate() {
        NSApp.activate()
        updaterController.checkForUpdates(nil)
    }
}

// Sparkle's standard user driver calls these on the main thread, so the
// conformance says so outright now that the class is main-actor isolated.
extension UpdateService: @MainActor SPUStandardUserDriverDelegate {

    /// Opt in to handling scheduled-update presentation ourselves; without
    /// this a dockless app gets Sparkle's focus-stealing default UI plus a
    /// log warning.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Never let a scheduled check pop UI; the panel's Update row is the
        // reminder. (User-initiated checks still show Sparkle's UI directly.)
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        latestVersion = update.displayVersionString
        hasUpdate = true
        // Not cleared on session end: a dismissed update is still pending, and
        // an installed one relaunches the app anyway.
    }
}
