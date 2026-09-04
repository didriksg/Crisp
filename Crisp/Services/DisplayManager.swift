import Foundation
import CoreGraphics
import AppKit

// Global C-compatible callback for display reconfiguration.
// Must be a top-level function (not a closure) to be used as a C function pointer.
private func displayReconfigCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let ptr = userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(ptr).takeUnretainedValue()

    // .movedFlag fires when a display's origin changes (a rearrange, in Crisp or
    // in System Settings). Without it the arranger keeps rendering stale bounds.
    let relevant: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .setMainFlag, .setModeFlag, .movedFlag]
    guard !flags.isDisjoint(with: relevant) else { return }

    // Skip the begin-configuration notification; only act when the change is complete.
    // (beginConfigurationFlag is set at the start of a transaction; absence means it finished.)
    guard !flags.contains(.beginConfigurationFlag) else { return }

    if !flags.isDisjoint(with: [.addFlag, .removeFlag, .movedFlag]) {
        BrightnessBoostService.advanceConnectionEpoch()
    }

    Task { @MainActor in
        ReconfigEvents.shared.resolve(displayID: displayID, flags: flags)
        if flags.isDisjoint(with: [.addFlag, .removeFlag, .movedFlag]) {
            // Mode or main-display change: refresh mode info for existing displays only.
            manager.refreshExistingDisplayModes()
        } else {
            // Add/remove/move: rebuild so display bounds (arrangement) are current;
            // refreshExistingDisplayModes doesn't re-read bounds.
            manager.refreshDisplays()
        }
    }
}

/// Awaitable one-shot bridge over the CG reconfiguration callback: suspend
/// until `displayID` posts a completed event matching `flags`, or the timeout
/// elapses (returns false). Replaces blind sleeps and polls for "the display
/// left the online list" / "the mode change landed". Events are not replayed,
/// so callers must check their condition right before awaiting; on a MainActor
/// caller that check-then-await is race-free (the resolving callback also runs
/// on the main actor), elsewhere the timeout bounds the miss at the old
/// fixed-sleep cost.
@MainActor
final class ReconfigEvents {
    static let shared = ReconfigEvents()
    private init() {}

    private struct Waiter {
        let displayID: CGDirectDisplayID
        let flags: CGDisplayChangeSummaryFlags
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    /// Called from the reconfiguration callback for completed changes only.
    func resolve(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        for (token, waiter) in waiters
        where waiter.displayID == displayID && !flags.isDisjoint(with: waiter.flags) {
            waiters.removeValue(forKey: token)
            waiter.continuation.resume(returning: true)
        }
    }

    @discardableResult
    func next(
        for displayID: CGDirectDisplayID,
        matching flags: CGDisplayChangeSummaryFlags,
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let token = UUID()
            waiters[token] = Waiter(displayID: displayID, flags: flags, continuation: continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let waiter = self?.waiters.removeValue(forKey: token) else { return }
                waiter.continuation.resume(returning: false)
            }
        }
    }
}

@MainActor
class DisplayManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    /// Display whose menu bar the panel was opened on; listed first, like the native displays panel.
    @Published var activePanelDisplayID: CGDirectDisplayID?

    /// A smooth-scaling toggle soft-reconnects the display, which drops it from the list and
    /// re-adds it as a fresh DisplayInfo, wiping its row's expansion @State. The enable flow
    /// sets this to the display's stable UUID afterward so the menu re-expands that display's
    /// detail and Resolution section, landing the user back where they were. Cleared once applied.
    @Published var pendingResolutionExpandUUID: String?

    // nonisolated(unsafe) allows deinit (which is nonisolated in Swift 6) to access this value.
    nonisolated(unsafe) private var callbackContext: UnsafeMutableRawPointer?
    nonisolated(unsafe) private var screenParamsObserver: NSObjectProtocol?

    init() {
        refreshDisplays()
        setupReconfigCallback()
        // On connect, the CG reconfiguration callback fires before AppKit's
        // NSScreen.screens includes the new display, so DisplayInfo.init can miss
        // the monitor's localized name and fall back to "Display N" for good.
        // AppKit posts this notification exactly when its screen list is current,
        // which is the first moment the lookup is guaranteed to see the display.
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.refreshDisplayNames() }
        }
    }

    deinit {
        if let ctx = callbackContext {
            CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, ctx)
            Unmanaged<DisplayManager>.fromOpaque(ctx).release()
        }
        if let obs = screenParamsObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Re-resolve display names against the now-current NSScreen list, replacing
    /// any "Display N" fallback a connect-time race left behind (and tracking
    /// renames macOS applies to its own list).
    private func refreshDisplayNames() {
        for display in displays where !display.isBuiltin {
            if let real = NSScreen.screen(for: display.displayID)?.localizedName,
               real != display.name {
                display.name = real
            }
        }
    }

    func refreshDisplays() {
        // Display IDs can be reshuffled across a reconnect storm with no ID
        // ever leaving the online list (two panels swapping IDs), so the
        // per-removed-ID cleanup below can miss a now-crossed channel map.
        // Always drop the whole map; it lazily rebuilds with identity
        // matching on the next DDC operation.
        DDCService.shared.invalidateAllChannelMappings()

        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        let currentIDs = Set(displays.map { $0.displayID })
        let newIDSet = Set((0..<Int(displayCount)).map { displayIDs[$0] })

        // Clean up DDC cache for removed displays to prevent stale entries accumulating
        let removedIDs = currentIDs.subtracting(newIDSet)
        removedIDs.forEach {
            DDCService.shared.clearCache(for: $0)
            BrightnessService.shared.invalidateDDCState(for: $0)
            GammaService.shared.invalidate(for: $0)
            BrightnessBoostService.shared.invalidate(for: $0)
            VolumeService.shared.invalidate(for: $0)
        }
        // A mirrored physical unplugged, or its virtual master dying, must drop
        // the mirror bookkeeping (and the orphan virtual with it). Checked against
        // the online list, not removedIDs: the mirror virtual is never in
        // `displays` (skipped below), so its death would not show up there.
        MirroredModeService.shared.reconcile(online: newIDSet)

        // Diff-based refresh: keep existing DisplayInfo objects (preserves @Published state)
        let existingByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })

        var updatedDisplays: [DisplayInfo] = []
        var addedDisplays: [DisplayInfo] = []

        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            // A mirror virtual (#65) is a rendering trick, not a display: keep it out
            // so no view, preset, brightness path, or the arranger ever sees one.
            if MirroredModeService.isMirrorVirtual(id) { continue }
            if let existing = existingByID[id] {
                updatedDisplays.append(existing)
            } else {
                let info = DisplayInfo(displayID: id)
                updatedDisplays.append(info)
                addedDisplays.append(info)
            }
        }

        displays = updatedDisplays
        DisplayManagerAccessor.shared.displays = updatedDisplays

        // Reconcile any legacy CGDirectDisplayID-keyed gamma adjustment onto the stable
        // UUID key before anything below reapplies a saved adjustment (issue #32).
        GammaService.shared.migrateLegacyStateIfNeeded(for: updatedDisplays)
        BrightnessService.shared.migrateLegacySoftBrightnessIfNeeded(for: updatedDisplays)

        // Only load details / refresh brightness for newly appeared displays
        for display in addedDisplays {
            Task { await BrightnessService.shared.refreshBrightness(for: display) }
            VolumeService.shared.refreshVolume(for: display)
            // Monitors often answer DDC with nothing (or garbage) for the first
            // seconds after link training, and a failed connect-time read has no
            // retry: with auto-brightness on the panel poll skips externals, so a
            // stale slider seed would stick until the next panel open. One delayed
            // re-read heals it; the adopt deadband makes it a no-op if the first
            // read was fine. Volume rides the same retry: a failed first probe
            // would otherwise hide the slider until the next reconnect.
            if !display.isBuiltin {
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await BrightnessService.shared.refreshBrightness(for: display)
                    VolumeService.shared.refreshVolume(for: display)
                }
            }
            Task {
                await display.loadDetails()
                // Auto-enable HiDPI for new external 2K+ displays that don't have it yet
                if !display.isBuiltin {
                    await self.autoEnableHiDPIIfNeeded(for: display)
                }
            }
            // Restore saved gamma/software-brightness adjustments for the reconnected display.
            // Brief delay lets WindowServer settle before we write transfer tables.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                GammaService.shared.reapplyIfNeeded(for: display)
            }
        }

        // For displays that were already present, only update bounds/main flag (no DDC probe).
        let keptIDs = currentIDs.intersection(newIDSet)
        for display in updatedDisplays where keptIDs.contains(display.displayID) {
            display.bounds = CGDisplayBounds(display.displayID)
            display.isMain = CGDisplayIsMain(display.displayID) != 0
            // Reconfigurations (mode switches, post-wake link retraining) can reset
            // the transfer table macOS-side, losing gamma adjustments (issue #25).
            // Restore any active adjustment, same as added displays already get;
            // the in-memory reapply is a no-op when there is none.
            GammaService.shared.reapply(for: display.displayID)
        }

        // Keep the physical-disconnect list honest: drop any record whose display came back
        // online (re-plugged, or macOS re-enabled it).
        PhysicalDisplayToggleService.shared.reconcile()
        // Runs on every refresh, but is a cheap no-op unless a soft reconnect's dead-man
        // marker is set (mid-toggle crash, or a re-enable that failed outright). The service
        // skips any display whose soft reconnect is still mid-blink, so this can't race a
        // toggle's own retry loop even though the blink's reconfig events land here mid-toggle.
        Task { await PhysicalDisplayToggleService.shared.recoverStrandedSoftReconnect() }
        // Same idea for mirror-mode strays: unmirror any panel a crashed session
        // left mirroring one of our virtual displays. Cheap no-op otherwise.
        MirroredModeService.shared.recoverStrandedMirrors()
        // A physical unplug bypasses disconnect()'s last-screen guard: internal disabled via
        // Crisp + external cable pulled = zero active displays, all black. Bring one back.
        PhysicalDisplayToggleService.shared.restoreIfNoActiveDisplay()

        // Keep the built-in brightness observer pointed at the current built-in so the
        // slider tracks system brightness changes (keys, auto-brightness) live.
        BrightnessService.shared.startObservingBuiltinBrightness()
    }

    /// Auto-enables HiDPI plist override for external 2K+ displays that don't have it yet.
    /// This ensures switching between different monitors "just works" without manual re-enable.
    private func autoEnableHiDPIIfNeeded(for display: DisplayInfo) async {
        let vendor = display.vendorNumber
        let product = display.modelNumber
        guard vendor != 0, product != 0 else { return }

        // Already enabled, nothing to do
        guard !HiDPIService.shared.isHiDPIEnabled(vendor: vendor, product: product) else { return }

        // Determine native resolution from available modes
        let (nativeW, nativeH) = display.nativeResolution

        // Only auto-enable for 2K+ displays (width >= 2560 or total pixels >= 2560*1440)
        guard nativeW >= 2560 || (nativeW * nativeH >= 2560 * 1440) else { return }

        // CGS-direct already surfaces the panel's HiDPI scaled modes with no override (the normal
        // case for 2K+ panels). When those are present, skip the override write + soft-reconnect
        // entirely: no admin prompt, no blank. The override path below is only a fallback for a
        // panel that genuinely lacks HiDPI in CGS.
        if display.availableModes.contains(where: {
            $0.isHiDPI && $0.pixelWidth >= nativeW && $0.width >= nativeW / 2
        }) { return }

        // Install the dense smooth-scaling ladder directly, not just the coarse HiDPI set: this
        // admin prompt is the one interruption, so make it deliver the full scaled slider in one
        // shot. Anyone enabling HiDPI on a 2K+ external wants that range anyway.
        // Panel-space dims: the override plist is rotation-blind (see panelNativeResolution).
        let (panelW, panelH) = display.panelNativeResolution
        let err = HiDPIService.shared.enableSmoothScaling(
            vendor: vendor, product: product, nativeWidth: panelW, nativeHeight: panelH)

        // On success, soft-reconnect so the freshly written override enumerates now (screen
        // blanks ~1s), instead of the weak probe that left the modes dormant until a physical
        // reconnect.
        if err == nil {
            await PhysicalDisplayToggleService.shared.softReconnect(display)
            HiDPIService.shared.refreshModes(for: display)
            await display.loadDetails()
        }
    }

    private func setupReconfigCallback() {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        callbackContext = ctx
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, ctx)
    }

    /// Refreshes mode info and main-display flag for already-tracked displays
    /// (for setModeFlag / setMainFlag events).
    /// Cheaper than a full `refreshDisplays()`, does not add/remove DisplayInfo objects.
    func refreshExistingDisplayModes() {
        for display in displays {
            // Always refresh isMain synchronously since it's cheap and needed for setMainFlag events.
            display.isMain = CGDisplayIsMain(display.displayID) != 0
            Task {
                let newMode = await Task.detached(priority: .userInitiated) {
                    DisplayMode.currentMode(for: display.displayID)
                }.value
                display.currentDisplayMode = newMode
            }
        }
    }

    /// Disconnects a physical display from the layout (Apple Silicon only) via
    /// PhysicalDisplayToggleService. Returns false if unsupported or refused (e.g. it would
    /// leave no active display). The display list refreshes via the reconfiguration callback.
    @discardableResult
    func disconnectDisplay(_ display: DisplayInfo) async -> Bool {
        let result = await PhysicalDisplayToggleService.shared.disconnect(display)
        refreshDisplays()
        if case .success = result { return true }
        return false
    }

    /// Makes the target display the main display by repositioning it to origin (0, 0).
    func setAsMainDisplay(_ display: DisplayInfo) {
        Task { @MainActor in
            let ok = await ArrangementService.shared.setAsMainDisplay(display.displayID, among: self.displays)
            if ok { self.refreshDisplays() }
        }
    }

}
