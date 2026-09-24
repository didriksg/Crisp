import Foundation
import CoreGraphics
import AppKit

// Must be a top-level function, not a closure, to be used as a C function pointer.
private func displayReconfigCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let ptr = userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(ptr).takeUnretainedValue()

    // .movedFlag: without it the arranger keeps rendering stale bounds after a rearrange.
    let relevant: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .setMainFlag, .setModeFlag, .movedFlag]
    guard !flags.isDisjoint(with: relevant) else { return }
    guard !flags.contains(.beginConfigurationFlag) else { return }

    Task { @MainActor in
        ReconfigEvents.shared.resolve(displayID: displayID, flags: flags)
        if flags.isDisjoint(with: [.addFlag, .removeFlag, .movedFlag]) {
            manager.refreshExistingDisplayModes()
        } else {
            // refreshExistingDisplayModes doesn't re-read bounds, so add/remove/move needs a rebuild.
            manager.refreshDisplays()
        }
    }
}

/// Awaitable bridge over the CG reconfiguration callback: suspend until `displayID` posts a
/// completed event matching `flags`, or the timeout elapses. Replaces blind sleeps/polls.
/// Events aren't replayed, so callers must check their condition right before awaiting; a
/// MainActor caller is race-free with the resolving callback, others bound the miss to `timeout`.
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

    /// What each external display ID named at the last refresh, so only the IDs whose
    /// fingerprint actually changed invalidate their DDC transport (not an untouched display).
    private var externalChannelFingerprints: [CGDirectDisplayID: String] = [:]

    // nonisolated(unsafe) so deinit (nonisolated in Swift 6) can access this.
    nonisolated(unsafe) private var callbackContext: UnsafeMutableRawPointer?
    nonisolated(unsafe) private var screenParamsObserver: NSObjectProtocol?

    init() {
        PhysicalDisplayToggleService.shared.displayManager = self
        refreshDisplays()
        setupReconfigCallback()
        // The CG reconfiguration callback fires before NSScreen.screens includes a new
        // display, so DisplayInfo.init can miss its localized name; this notification is the
        // first moment AppKit's screen list is guaranteed current.
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
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

    /// Replaces a "Display N" fallback left by the connect-time race (see init), and
    /// tracks renames macOS applies to its own list.
    private func refreshDisplayNames() {
        for display in displays where !display.isBuiltin {
            if let real = NSScreen.screen(for: display.displayID)?.localizedName,
               real != display.name {
                display.name = real
            }
        }
    }

    /// Invalidates DDC only for externals whose physical channel actually changed, not every
    /// online display, so plugging in one monitor can't cancel a pending write or fade on another.
    private func invalidateDDCTopologyForChangedChannels(online newIDSet: Set<CGDirectDisplayID>) {
        var fingerprints: [CGDirectDisplayID: String] = [:]
        for id in newIDSet where CGDisplayIsBuiltin(id) == 0 && !MirroredModeService.isMirrorVirtual(id) {
            fingerprints[id] = externalChannelFingerprint(for: id)
        }

        let changed = DDCTopologyChange.changedChannels(
            previous: externalChannelFingerprints,
            current: fingerprints
        )
        externalChannelFingerprints = fingerprints

        guard !changed.isEmpty else { return }
        BrightnessService.shared.invalidateDDCTopology(for: changed)
    }

    /// Identity plus location: two identical monitors share vendor/product/serial, so
    /// location is what tells them apart when macOS swaps their IDs.
    private func externalChannelFingerprint(for displayID: CGDirectDisplayID) -> String {
        let location = DDCService.shared.channelLocation(for: displayID) ?? ""
        return "\(CGDisplayVendorNumber(displayID))/\(CGDisplayModelNumber(displayID))"
            + "/\(CGDisplaySerialNumber(displayID))/\(location)"
    }

    func refreshDisplays() {
        // Display IDs can be reshuffled across a reconnect storm with no ID leaving the
        // online list, so drop the whole channel map; it lazily rebuilds on the next DDC op.
        DDCService.shared.invalidateAllChannelMappings()

        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        let currentIDs = Set(displays.map { $0.displayID })
        let newIDSet = Set((0..<Int(displayCount)).map { displayIDs[$0] })
        invalidateDDCTopologyForChangedChannels(online: newIDSet)

        let removedIDs = currentIDs.subtracting(newIDSet)
        removedIDs.forEach {
            DDCService.shared.clearCache(for: $0)
            BrightnessService.shared.invalidateDDCState(for: $0)
            GammaService.shared.invalidate(for: $0)
            BrightnessBoostService.shared.invalidate(for: $0)
            VolumeService.shared.invalidate(for: $0)
        }
        // Checked against the online list, not removedIDs: the mirror virtual is never in
        // `displays`, so its death wouldn't show up there otherwise.
        MirroredModeService.shared.reconcile(online: newIDSet)

        // Keep existing DisplayInfo objects to preserve @Published state.
        let existingByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })

        var updatedDisplays: [DisplayInfo] = []
        var addedDisplays: [DisplayInfo] = []

        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            // A mirror virtual (#65) is a rendering trick, not a display: keep it out entirely.
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
            // Monitors often answer DDC with garbage for the first seconds after link
            // training, and a failed connect-time read has no other retry; a delayed
            // re-read heals a stale slider seed (no-op if the first read was fine).
            if !display.isBuiltin {
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await BrightnessService.shared.refreshBrightness(for: display)
                    VolumeService.shared.refreshVolume(for: display)
                }
            }
            Task {
                await display.loadDetails()
                if !display.isBuiltin {
                    await self.autoEnableHiDPIIfNeeded(for: display)
                }
            }
            // Brief delay lets WindowServer settle before writing transfer tables.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                GammaService.shared.reapplyIfNeeded(for: display)
            }
        }

        // Kept displays: only bounds/main flag, no DDC probe.
        let keptIDs = currentIDs.intersection(newIDSet)
        for display in updatedDisplays where keptIDs.contains(display.displayID) {
            display.bounds = CGDisplayBounds(display.displayID)
            display.isMain = CGDisplayIsMain(display.displayID) != 0
            // Reconfigurations can reset the transfer table macOS-side, losing gamma
            // adjustments (issue #25); no-op when there's none to restore.
            GammaService.shared.reapply(for: display.displayID)
        }

        // Drops any physical-disconnect record whose display came back online.
        PhysicalDisplayToggleService.shared.reconcile()
        Task { await PhysicalDisplayToggleService.shared.recoverStrandedSoftReconnect() }
        MirroredModeService.shared.recoverStrandedMirrors()
        // A physical unplug bypasses disconnect()'s last-screen guard. See docs/display-notes.md
        // (restoreIfNoActiveDisplay).
        PhysicalDisplayToggleService.shared.restoreIfNoActiveDisplay()

        BrightnessService.shared.startObservingNativeBrightness(for: displays)
    }

    /// Auto-enables HiDPI plist override for external 2K+ displays that don't have it yet.
    private func autoEnableHiDPIIfNeeded(for display: DisplayInfo) async {
        let vendor = display.vendorNumber
        let product = display.modelNumber
        guard vendor != 0, product != 0 else { return }

        guard !HiDPIService.shared.isHiDPIEnabled(vendor: vendor, product: product) else { return }

        let (nativeW, nativeH) = display.nativeResolution

        guard nativeW >= 2560 || (nativeW * nativeH >= 2560 * 1440) else { return }

        // CGS-direct already surfaces HiDPI scaled modes with no override for most 2K+ panels;
        // skip the write and its admin prompt/blank when that's already true.
        if display.availableModes.contains(where: {
            $0.isHiDPI && $0.pixelWidth >= nativeW && $0.width >= nativeW / 2
        }) { return }

        // Installs the dense smooth-scaling ladder directly (not just coarse HiDPI), since the
        // admin prompt is the one interruption. Panel-space dims: the plist is rotation-blind.
        let (panelW, panelH) = display.panelNativeResolution
        let err = HiDPIService.shared.enableSmoothScaling(
            vendor: vendor, product: product, nativeWidth: panelW, nativeHeight: panelH)

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

    /// Cheaper than refreshDisplays(): refreshes mode/main-flag for tracked displays without
    /// adding or removing DisplayInfo objects.
    func refreshExistingDisplayModes() {
        for display in displays {
            display.isMain = CGDisplayIsMain(display.displayID) != 0
            Task {
                let newMode = await Task.detached(priority: .userInitiated) {
                    DisplayMode.currentMode(for: display.displayID)
                }.value
                display.currentDisplayMode = newMode
            }
        }
    }

    /// Returns false if unsupported or refused (e.g. it would leave no active display).
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
