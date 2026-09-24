// Crisp/Services/BrightnessBoostService.swift
import AppKit
import CoreGraphics

/// Policy brain for the Extra Brightness (EDR upscaling) feature. Decides which
/// displays can boost, maps brightness above 100% to an overlay factor (via
/// BrightnessBoostMath + EDROverlayManager), switches external monitors into
/// HDR mode when boost needs it, and persists the per-display toggle by
/// displayUUID. Also exposes the explicit per-display HDR toggle (private
/// MonitorPanel.framework, same dlopen + KVC pattern as DisplayPresetService).
@MainActor
final class BrightnessBoostService {
    static let shared = BrightnessBoostService()

    /// MPDisplayMgr instance; nil when MonitorPanel is unavailable.
    private let manager: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil,
              let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    /// Animates DisplayInfo.maxBrightness for the slider range glide, and
    /// doubles as the disable-collapse animator's home (collapseAndDisable),
    /// so a rapid re-enable cancels whichever of the two is running.
    private var maxAnimators: [CGDirectDisplayID: BrightnessAnimator] = [:]

    private func animateMaxBrightness(to target: Double, for display: DisplayInfo) {
        let animator = maxAnimators[display.displayID] ?? BrightnessAnimator()
        maxAnimators[display.displayID] = animator
        animator.animate(
            from: display.maxBrightness, to: target,
            steps: max(8, Int(0.2 / 0.008)), duration: 0.2
        ) { [weak display] value, _ in
            display?.maxBrightness = value
        }
    }

    /// Displays currently running the disable-collapse animation (see
    /// collapseAndDisable below). syncOverlay returns early for these so the
    /// headroom poll and other callers cannot fight the collapse mid-flight.
    private var collapsingDisplays: Set<CGDirectDisplayID> = []

    /// Re-clamps the overlay factor while boost is engaged: deliverable
    /// headroom drifts with panel brightness and thermals with no reliable
    /// notification. Ends itself once nothing is boosted. See
    /// docs/brightness-notes.md (Extra Brightness (EDR boost)).
    private var headroomPollTask: Task<Void, Never>?

    /// Pending post-reconfiguration reconcile. One at a time: a connect or
    /// disconnect storm posts didChangeScreenParametersNotification many
    /// times, and each reapplyAll is a full DDC/gamma/overlay pass.
    private var reapplyAfterReconfigTask: Task<Void, Never>?

    /// Debounces auto-disable when an enabled external's headroom drops to
    /// nothing: fires only after the loss persists 1.5s (wall clock) to ride
    /// out transient dips during mode-change storms. See
    /// docs/brightness-notes.md (Extra Brightness (EDR boost)).
    private var headroomLossSince: [CGDirectDisplayID: Date] = [:]

    /// While set and in the future, the poll runs at 16ms instead of 500ms,
    /// to track the EDR ramp right after a display enters the boost region.
    /// See docs/brightness-notes.md (Extra Brightness (EDR boost)).
    private var fastPollUntil: Date?
    /// Displays whose overlay factor is currently above identity; used to
    /// detect the first entry into the boost region (arms fastPollUntil).
    private var activeBoostDisplays: Set<CGDirectDisplayID> = []

    private func startHeadroomPollIfNeeded() {
        guard headroomPollTask == nil else { return }
        headroomPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let fast = self.flatMap { s in s.fastPollUntil.map { Date() < $0 } } ?? false
                try? await Task.sleep(nanoseconds: fast ? 16_000_000 : 500_000_000)
                guard let self else { return }
                var anyBoosted = false
                // Also visits inert-but-enabled displays (flag set, capability
                // currently missing) so the debounced auto-disable below can
                // resolve them; syncOverlay no-ops for them.
                for display in DisplayManagerAccessor.shared.displays
                where display.maxBrightness > 100 || self.isEnabled(for: display) {
                    anyBoosted = true
                    self.syncOverlay(for: display)
                    guard !display.isBuiltin else { continue }
                    guard self.isEnabled(for: display), self.potentialHeadroom(for: display.displayID) <= 1.05 else {
                        self.headroomLossSince.removeValue(forKey: display.displayID)
                        continue
                    }
                    let since = self.headroomLossSince[display.displayID] ?? Date()
                    self.headroomLossSince[display.displayID] = since
                    if Date().timeIntervalSince(since) >= 1.5 {
                        self.headroomLossSince.removeValue(forKey: display.displayID)
                        await self.setEnabled(false, for: display)
                    }
                }
                if !anyBoosted {
                    self.headroomPollTask = nil
                    return
                }
            }
        }
    }

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // MARK: - Persistence (displayUUID keyed, survives displayID reassignment)

    private func enabledKey(_ uuid: String) -> String { "crisp.BoostEnabled.\(uuid)" }
    /// Set when boost itself switched an external into HDR mode, so disabling
    /// can revert it; untouched when the user already had HDR on.
    private func switchedHDRKey(_ uuid: String) -> String { "crisp.BoostSwitchedHDR.\(uuid)" }

    func isEnabled(for display: DisplayInfo) -> Bool {
        UserDefaults.standard.bool(forKey: enabledKey(display.displayUUID))
    }

    // MARK: - Screen and headroom helpers

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screen(for: displayID)
    }

    /// Potential headroom: what the display could do (basis for eligibility and
    /// the slider ceiling). 1.0 on SDR-only displays.
    private func potentialHeadroom(for displayID: CGDirectDisplayID) -> Double {
        guard let s = screen(for: displayID) else { return 1.0 }
        return Double(s.maximumPotentialExtendedDynamicRangeColorComponentValue)
    }

    /// Current headroom: what the display can do right now (basis for clamping
    /// the overlay factor; macOS moves this with panel brightness and thermals).
    private func currentHeadroom(for displayID: CGDirectDisplayID) -> Double {
        guard let s = screen(for: displayID) else { return 1.0 }
        return Double(s.maximumExtendedDynamicRangeColorComponentValue)
    }

    // MARK: - Eligibility

    /// A display can boost when it reports usable EDR headroom (built-in XDR,
    /// or an external already in HDR mode) or when we know how to switch it
    /// into HDR mode (external with MonitorPanel HDR support).
    func isEligible(_ display: DisplayInfo) -> Bool {
        guard display.isOnline, !VirtualDisplayService.shared.isVirtualDisplay(display.displayID) else { return false }
        if potentialHeadroom(for: display.displayID) > 1.05 { return true }
        if !display.isBuiltin, supportsHDRMode(display.displayID) { return true }
        return false
    }

    /// Live logical ceiling exposed to automation. Unlike DisplayInfo.maxBrightness,
    /// this is not transiently lower while the UI range expansion is animating.
    func maximumBrightness(for display: DisplayInfo) -> Double {
        guard isEnabled(for: display), isEligible(display) else { return 100 }
        return BrightnessBoostMath.sliderMax(potentialHeadroom: potentialHeadroom(for: display.displayID))
    }

    /// An accepted CLI set must not be clamped by the remaining range animation.
    func settleMaximumBrightness(_ maximum: Double, for display: DisplayInfo) {
        maxAnimators[display.displayID]?.cancel()
        display.maxBrightness = maximum
    }

    // MARK: - Toggle

    /// Enables or disables boost. Async: switching an external into HDR mode
    /// needs time to settle. Returns false when enabling failed (caller
    /// reverts the toggle UI); `revertOwnHDR` false skips the HDR revert on
    /// disable, for the explicit HDR-off path, which switches modes itself.
    @discardableResult
    func setEnabled(_ enabled: Bool, for display: DisplayInfo, revertOwnHDR: Bool = true) async -> Bool {
        let uuid = display.displayUUID
        if enabled {
            // Cancel any disable-collapse still running from a rapid off/on
            // flip, and clear the collapsing marker so syncOverlay stops
            // skipping this display.
            BrightnessService.shared.cancelAnimation(for: display.displayID)
            maxAnimators[display.displayID]?.cancel()
            collapsingDisplays.remove(display.displayID)
            // Externals in SDR mode: switch to HDR first.
            var switchedHDRForThisAttempt: (uuid: String, token: UUID)?
            if !display.isBuiltin, potentialHeadroom(for: display.displayID) <= 1.05 {
                guard let targetUUID = uniqueDisplayUUID(for: display),
                      supportsHDRMode(display.displayID) else { return false }
                let requestToken = UUID()
                hdrRequestTokens[display.displayID] = requestToken
                guard setHDRMode(
                    true, for: display, expectedUUID: targetUUID,
                    requestToken: requestToken
                ) else { return false }
                switchedHDRForThisAttempt = (targetUUID, requestToken)
                // Give WindowServer a moment to re-sync the display in HDR mode.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            let potential = potentialHeadroom(for: display.displayID)
            let newMax = BrightnessBoostMath.sliderMax(potentialHeadroom: potential)
            guard newMax > 100 else {
                // No usable headroom: fail quietly, and roll back an HDR
                // switch made by THIS attempt (a half-engaged switch leaves
                // HDR rendering into an SDR link). A user-set HDR mode is
                // left alone.
                if let request = switchedHDRForThisAttempt {
                    _ = setHDRMode(
                        false, for: display, expectedUUID: request.uuid,
                        requestToken: request.token
                    )
                }
                return false
            }
            UserDefaults.standard.set(true, forKey: enabledKey(uuid))
            if switchedHDRForThisAttempt != nil {
                UserDefaults.standard.set(true, forKey: switchedHDRKey(uuid))
            }
            animateMaxBrightness(to: newMax, for: display)
            syncOverlay(for: display)
            return true
        } else {
            let switchedHDR = UserDefaults.standard.bool(forKey: switchedHDRKey(uuid))
            UserDefaults.standard.removeObject(forKey: switchedHDRKey(uuid))
            UserDefaults.standard.set(false, forKey: enabledKey(uuid))
            collapseAndDisable(for: display)
            // Revert HDR only if boost switched it on for itself; already-off
            // HDR means nothing to undo.
            if revertOwnHDR, switchedHDR, !display.isBuiltin, isHDREnabled(for: display) {
                _ = await setHDRPreference(false, for: display)
            }
            return true
        }
    }

    /// Combined collapse: brightness and maxBrightness glide back to 100
    /// together from one progress animator (a two-phase version made the
    /// slider thumb visibly drop then rise; see docs/brightness-notes.md).
    /// The overlay factor uses the frozen starting maxBrightness (max0), not
    /// the live shrinking one, so the multiplier tracks the thumb.
    private func collapseAndDisable(for display: DisplayInfo) {
        let displayID = display.displayID
        let v0 = display.brightness
        let max0 = display.maxBrightness
        guard abs(v0 - 100) > 0.001 || abs(max0 - 100) > 0.001 else {
            finishDisable(for: display)
            return
        }
        collapsingDisplays.insert(displayID)
        let animator = maxAnimators[displayID] ?? BrightnessAnimator()
        maxAnimators[displayID] = animator
        animator.animate(
            from: 1.0, to: 0.0,
            steps: max(8, Int(0.35 / 0.008)), duration: 0.35
        ) { [weak self, weak display] p, isLast in
            guard let self else { return }
            guard let display else {
                // Deallocated mid-collapse (disconnect): drop the marker so a
                // reused CGDirectDisplayID isn't stuck with syncOverlay muted.
                self.collapsingDisplays.remove(displayID)
                self.maxAnimators[displayID]?.cancel()
                return
            }
            // A brightness already at or below 100 is in the native range and
            // must stay put; only the boosted excess collapses toward 100.
            let vEnd = min(v0, 100)
            display.brightness = vEnd + p * (v0 - vEnd)
            display.maxBrightness = 100 + p * (max0 - 100)
            if display.isBuiltin {
                let factor = BrightnessBoostMath.overlayFactor(
                    brightness: display.brightness, sliderMax: max0,
                    currentEDR: self.currentHeadroom(for: displayID),
                    potentialHeadroom: self.potentialHeadroom(for: displayID)
                )
                EDROverlayManager.shared.setFactor(factor, for: displayID)
            } else {
                let factor = BrightnessBoostMath.externalBoostFactor(
                    brightness: display.brightness, sliderMax: max0)
                BrightnessService.shared.setBoostFactor(factor, for: displayID)
            }
            if isLast {
                self.collapsingDisplays.remove(displayID)
                self.finishDisable(for: display)
            }
        }
    }

    private func finishDisable(for display: DisplayInfo) {
        // Close the EDR surface only after everything is static: closing
        // exits EDR mode, and doing that mid-motion is what flashed.
        let displayID = display.displayID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !self.isEnabled(for: display) else { return }
            EDROverlayManager.shared.removeOverlay(for: displayID)
        }
    }

    // MARK: - Overlay sync (called on every brightness change)

    /// Recomputes and applies the overlay factor for the display's current
    /// brightness, clamped against live headroom (see
    /// BrightnessBoostMath.overlayFactor and docs/brightness-notes.md for the
    /// ramp-in and auto-disable behavior this feeds).
    func syncOverlay(for display: DisplayInfo) {
        guard display.maxBrightness > 100 else { return }
        // The disable-collapse animation drives the overlay factor itself;
        // running concurrently (e.g. from the headroom poll) would fight it.
        guard !collapsingDisplays.contains(display.displayID) else { return }
        if display.isBuiltin {
            let factor = BrightnessBoostMath.overlayFactor(
                brightness: display.brightness,
                sliderMax: display.maxBrightness,
                currentEDR: currentHeadroom(for: display.displayID),
                potentialHeadroom: potentialHeadroom(for: display.displayID)
            )
            EDROverlayManager.shared.setFactor(factor, for: display.displayID)
            // First entry into the boost region arms the fast-poll window: the
            // EDR ramp that follows is what the poll needs to track closely.
            if factor > 1.001 {
                if activeBoostDisplays.insert(display.displayID).inserted {
                    fastPollUntil = Date().addingTimeInterval(3.0)
                }
            } else {
                activeBoostDisplays.remove(display.displayID)
            }
        } else {
            // Externals boost via the display transfer table, not an EDR
            // overlay (see BrightnessBoostMath.externalBoostCeiling). Written
            // unconditionally so the poll re-heals the table after an
            // ICC-restore clobber.
            let factor = BrightnessBoostMath.externalBoostFactor(
                brightness: display.brightness, sliderMax: display.maxBrightness)
            BrightnessService.shared.setBoostFactor(factor, for: display.displayID)
        }
        if display.maxBrightness > 100 { startHeadroomPollIfNeeded() }
    }

    // MARK: - Lifecycle

    /// Re-establish boost state for every connected display. Called at launch,
    /// after wake, and on display reconfiguration.
    func reapplyAll() {
        syncHDRRouting()
        var anyEnabled = false
        for display in DisplayManagerAccessor.shared.displays where isEnabled(for: display) {
            anyEnabled = true
            guard isEligible(display) else { continue }
            let potential = potentialHeadroom(for: display.displayID)
            let newMax = BrightnessBoostMath.sliderMax(potentialHeadroom: potential)
            // No usable headroom right now: leave the decision to the
            // headroom poll's debounced auto-disable; wake/reconfig reads
            // are unreliable single samples.
            guard newMax > 100 else { continue }
            display.maxBrightness = newMax
            syncOverlay(for: display)
        }
        // Watch every enabled display, including inert ones, so the debounced
        // auto-disable can resolve them into a coherent off state.
        if anyEnabled { startHeadroomPollIfNeeded() }
        EDROverlayManager.shared.rerenderAll()
    }

    /// Quit: drop overlays (they die with the process anyway). HDR mode is
    /// left as the user set it: it is now an explicit per-display toggle (see
    /// HDRToggleView), and boost no longer silently reverts it on exit.
    func prepareForTermination() {
        EDROverlayManager.shared.removeAll()
    }

    /// Drop all per-display state for a disconnected display so a reused
    /// displayID cannot inherit it (same hazard as BrightnessService's
    /// invalidateDDCState; DisplayManager calls both from its removed loop).
    func invalidate(for displayID: CGDirectDisplayID) {
        maxAnimators[displayID]?.cancel()
        maxAnimators.removeValue(forKey: displayID)
        headroomLossSince.removeValue(forKey: displayID)
        hdrRequestTokens.removeValue(forKey: displayID)
        collapsingDisplays.remove(displayID)
        hdrSupportCache.removeValue(forKey: displayID)
    }

    @objc private func screenParametersChanged() {
        // DisplayIDs can be reassigned across a reconfiguration; drop the
        // capability cache before anything re-reads it.
        hdrSupportCache.removeAll()
        // Reconcile ONCE after connect/disconnect storms settle (mirrors the
        // panel's own debounce; mid-reconfig geometry and headroom reads are
        // garbage): cancel any reconcile a previous notification scheduled.
        reapplyAfterReconfigTask?.cancel()
        reapplyAfterReconfigTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.reapplyAll()
        }
    }

    // MARK: - HDR toggle (explicit, per-display)

    /// Whether this display is offered the explicit HDR row at all: externals
    /// only (the built-in panel never shows it, matching System Settings)
    /// that MonitorPanel reports as HDR-capable.
    func isEligibleForHDRToggle(_ display: DisplayInfo) -> Bool {
        let displayID = display.displayID
        return CGDisplayIsOnline(displayID) != 0
            && CGDisplayIsBuiltin(displayID) == 0
            && supportsHDRMode(displayID)
    }

    /// Live HDR mode state, read straight from MPDisplay (not persisted: the
    /// OS already remembers HDR preference itself).
    func isHDREnabled(for display: DisplayInfo) -> Bool {
        guard let d = mpDisplay(for: display.displayID) else { return false }
        return (d.value(forKey: "preferHDRModes") as? Bool) == true
    }

    /// Returns nil when this runtime ID no longer names the expected online
    /// display or its HDR state cannot be read.
    func hdrState(for display: DisplayInfo, expectedUUID: String) -> Bool? {
        guard display.displayUUID.caseInsensitiveCompare(expectedUUID) == .orderedSame,
              isEligibleForHDRToggle(display),
              let d = mpDisplay(for: display.displayID) else { return nil }
        return d.value(forKey: "preferHDRModes") as? Bool
    }

    func mutationHDRState(for display: DisplayInfo, expectedUUID: String) -> Bool? {
        guard uniqueDisplayUUID(for: display)?.caseInsensitiveCompare(expectedUUID) == .orderedSame,
              isEligibleForHDRToggle(display),
              let d = mpDisplay(for: display.displayID) else { return nil }
        return d.value(forKey: "preferHDRModes") as? Bool
    }

    func uniqueDisplayUUID(for display: DisplayInfo) -> String? {
        let displayID = display.displayID
        guard CGDisplayIsOnline(displayID) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID),
              let uuidString = CFUUIDCreateString(nil, uuid.takeRetainedValue()) else { return nil }
        return uuidString as String
    }

    /// Current HDR-preference request token per display: guards a stale mode
    /// switch from firing after a newer request supersedes it mid-wait
    /// (setHDRPreference).
    private var hdrRequestTokens: [CGDirectDisplayID: UUID] = [:]

    /// Explicit HDR on/off. Turning off while boost is enabled first runs
    /// boost's own disable-collapse to completion, so brightness is back at
    /// 100 before the mode switch instead of fighting it underneath.
    @discardableResult
    func setHDRPreference(
        _ on: Bool, for display: DisplayInfo, expectedUUID: String? = nil
    ) async -> Bool {
        let displayID = display.displayID
        guard let targetUUID = expectedUUID ?? uniqueDisplayUUID(for: display),
              mutationHDRState(for: display, expectedUUID: targetUUID) != nil else { return false }
        let requestToken = UUID()
        hdrRequestTokens[displayID] = requestToken
        if on {
            return setHDRMode(
                true, for: display, expectedUUID: targetUUID,
                requestToken: requestToken
            )
        }
        if isEnabled(for: display) {
            _ = await setEnabled(false, for: display, revertOwnHDR: false)
        }
        // Wait on the live collapse set, not the isEnabled flag: a collapse
        // may already be animating this display with the flag cleared.
        // Capped at 2s so a cancelled animator can't spin this forever.
        var waited = 0
        while collapsingDisplays.contains(displayID), waited < 40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        // Brief settle so the collapse's last brightness write lands
        // before the mode switch.
        try? await Task.sleep(nanoseconds: 200_000_000)
        return setHDRMode(
            false, for: display, expectedUUID: targetUUID,
            requestToken: requestToken
        )
    }

    // MARK: - MonitorPanel HDR mode (private API; selectors verified by the Task 1 spike)

    private func mpDisplay(for displayID: CGDirectDisplayID) -> NSObject? {
        guard let displays = manager?.value(forKey: "displays") as? [NSObject] else { return nil }
        return displays.first { ($0.value(forKey: "displayID") as? UInt32) == displayID }
    }

    /// Hardware capability, cached per displayID: MPDisplay's read is a
    /// synchronous WindowServer round-trip hit on every HDR-toggle render.
    /// Cache clears on screen reconfiguration. See docs/brightness-notes.md
    /// (Extra Brightness (EDR boost)).
    private var hdrSupportCache: [CGDirectDisplayID: Bool] = [:]

    private func supportsHDRMode(_ displayID: CGDirectDisplayID) -> Bool {
        if let cached = hdrSupportCache[displayID] { return cached }
        guard let d = mpDisplay(for: displayID) else { return false }
        let supported = (d.value(forKey: "hasHDRModes") as? Bool) == true
        hdrSupportCache[displayID] = supported
        return supported
    }

    @discardableResult
    private func setHDRMode(
        _ on: Bool,
        for display: DisplayInfo,
        expectedUUID: String,
        requestToken: UUID
    ) -> Bool {
        let displayID = display.displayID
        guard isEligibleForHDRToggle(display) else { return false }
        guard let d = mpDisplay(for: displayID) else { return false }
        let sel = NSSelectorFromString("setPreferHDRModes:")
        guard d.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Void
        guard hdrRequestTokens[displayID] == requestToken,
              uniqueDisplayUUID(for: display)?.caseInsensitiveCompare(expectedUUID) == .orderedSame else {
            return false
        }
        unsafeBitCast(d.method(for: sel), to: Fn.self)(d, sel, on)
        BrightnessService.shared.setHDRSoftwareDimming(on, for: displayID)
        return true
    }

    /// Keeps BrightnessService.hdrDimmedDisplays in step with each external's
    /// live HDR mode, including flips made outside Crisp (every HDR change
    /// fires a reconfiguration, which lands here via reapplyAll).
    private func syncHDRRouting() {
        // Every external gets an explicit answer, not just HDR-eligible ones:
        // a reused ID inheriting state from a disconnected HDR display must
        // be actively cleared out of software dimming.
        for display in DisplayManagerAccessor.shared.displays where !display.isBuiltin {
            let dimmed = isEligibleForHDRToggle(display) && isHDREnabled(for: display)
            BrightnessService.shared.setHDRSoftwareDimming(dimmed, for: display.displayID)
        }
    }
}
