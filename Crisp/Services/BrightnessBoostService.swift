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

    /// Animates DisplayInfo.maxBrightness so the slider range grows and
    /// shrinks with the same ~125Hz ease-out glide brightness itself uses,
    /// instead of snapping the thumb to a new position. Also holds the
    /// disable-collapse animator (see collapseAndDisable), keyed the same way
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

    /// While any boost is engaged, the display's deliverable headroom moves
    /// with panel brightness and thermals, and macOS does not reliably post a
    /// notification when it drops. A factor above the deliverable range clips
    /// bright content to white, so poll and re-clamp; the loop ends itself
    /// once nothing is boosted.
    private var headroomPollTask: Task<Void, Never>?

    /// Pending post-reconfiguration reconcile. One at a time: a connect or
    /// disconnect storm posts didChangeScreenParametersNotification many
    /// times, and each reapplyAll is a full DDC/gamma/overlay pass.
    private var reapplyAfterReconfigTask: Task<Void, Never>?

    /// When an enabled external first reported potentialHeadroom at or below
    /// hdrReadyThreshold: HDR capability disappeared out from under it (user
    /// turned HDR off, or a HiDPI mode switch dropped HDR advertisement).
    /// Auto-disable fires only after the loss has persisted 1.5s (wall clock,
    /// so the fast-poll window cannot rush it) to ride out transient dips
    /// during mode-change storms.
    private var headroomLossSince: [CGDirectDisplayID: Date] = [:]

    /// While set and in the future, the poll runs at 16ms instead of 500ms.
    /// Armed when a display first enters the boost region: macOS ramps EDR
    /// headroom over the next second or two, and catching that ramp in 500ms
    /// chunks reads as laggy, steppy brightness right when the user starts
    /// pushing the slider past 100.
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
                // Visit inert-but-enabled displays too (flag set, capability
                // currently missing, maxBrightness back at 100): the debounced
                // auto-disable below is what resolves them; syncOverlay
                // no-ops for them.
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

    // MARK: - Toggle

    /// Enable or disable boost. Async because switching an external monitor to
    /// HDR mode takes a moment to settle. Returns false when enabling failed
    /// (caller reverts the toggle UI).
    @discardableResult
    func setEnabled(_ enabled: Bool, for display: DisplayInfo) async -> Bool {
        let uuid = display.displayUUID
        if enabled {
            // A disable-collapse may still be running from a rapid off/on
            // flip; cancel it where it is (through the same maxAnimators slot
            // the collapse itself uses) so it cannot keep walking brightness
            // down after we re-enable, and clear isCollapsing so syncOverlay
            // stops skipping this display.
            BrightnessService.shared.cancelAnimation(for: display.displayID)
            maxAnimators[display.displayID]?.cancel()
            collapsingDisplays.remove(display.displayID)
            // Externals in SDR mode: switch to HDR first.
            var switchedHDRForThisAttempt = false
            if !display.isBuiltin, potentialHeadroom(for: display.displayID) <= 1.05 {
                guard supportsHDRMode(display.displayID), setHDRMode(true, for: display.displayID) else { return false }
                switchedHDRForThisAttempt = true
                // Give WindowServer a moment to re-sync the display in HDR mode.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            let potential = potentialHeadroom(for: display.displayID)
            let newMax = BrightnessBoostMath.sliderMax(potentialHeadroom: potential)
            guard newMax > 100 else {
                // No usable headroom: fail quietly. A user-set HDR mode is
                // left alone (explicit toggle), but an HDR switch made by
                // THIS failed attempt is rolled back: a half-engaged switch
                // (preference recorded, mode never applied) leaves the OS
                // rendering HDR into an SDR link, washing the screen out.
                if switchedHDRForThisAttempt {
                    _ = setHDRMode(false, for: display.displayID)
                }
                return false
            }
            UserDefaults.standard.set(true, forKey: enabledKey(uuid))
            animateMaxBrightness(to: newMax, for: display)
            syncOverlay(for: display)
            return true
        } else {
            UserDefaults.standard.set(false, forKey: enabledKey(uuid))
            collapseAndDisable(for: display)
            return true
        }
    }

    /// Single combined collapse: brightness and maxBrightness glide back to
    /// 100 together, driven by one progress animator, instead of fading
    /// brightness to 100 first and only then collapsing maxBrightness. That
    /// two-phase sequence made the slider thumb (value/max) visibly drop
    /// then rise; driving both from the same progress keeps it monotonic.
    /// sliderMax for the overlay factor is the frozen starting maxBrightness
    /// (max0), not the live (shrinking) one, so the multiplier tracks the
    /// thumb instead of jumping.
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
                // The display deallocated mid-collapse (disconnect). Drop the
                // collapse marker so a reconnect reusing this CGDirectDisplayID
                // is not stuck with syncOverlay muted forever.
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

    /// Recompute and apply the overlay factor for the display's current
    /// brightness. Live currentEDR gates the target: below
    /// BrightnessBoostMath.hdrReadyThreshold the panel has not ramped EDR yet,
    /// so a small pending factor is applied instead of the full target (see
    /// BrightnessBoostMath.overlayFactor); potentialHeadroom gates that pending
    /// factor itself, so a display genuinely back in SDR gets 1.0 instead of a
    /// nudge that can never ramp. Headroom changes post didChangeScreenParameters
    /// (observed above) and are also polled (see startHeadroomPollIfNeeded), so
    /// the factor converges to what the panel can actually deliver within a
    /// beat of engaging, and the poll auto-disables boost once potentialHeadroom
    /// stays lost for a display that needs it (see headroomLossPolls).
    func syncOverlay(for display: DisplayInfo) {
        guard display.maxBrightness > 100 else { return }
        // The disable-collapse animation drives the overlay factor itself;
        // letting this run concurrently (e.g. from the headroom poll) would
        // fight it.
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
            // Externals boost through the display transfer table, not the EDR
            // overlay (see BrightnessBoostMath.externalBoostCeiling for why).
            // Written unconditionally: the 500ms poll landing here re-heals
            // the table after an ICC-restore clobber without extra plumbing.
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
            // No usable headroom right now: do NOT decide anything here. Wake
            // and reconfig headroom reads are unreliable single samples; the
            // headroom poll below owns auto-disable with a debounce, and
            // re-engagement happens on the next reapply once reads are sane.
            guard newMax > 100 else { continue }
            display.maxBrightness = newMax
            syncOverlay(for: display)
        }
        // Ensure the poll is watching every enabled display, including inert
        // ones (flag set but capability currently missing), so the debounced
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
        !display.isBuiltin && supportsHDRMode(display.displayID)
    }

    /// Live HDR mode state, read straight from MPDisplay (not persisted: the
    /// OS already remembers HDR preference itself).
    func isHDREnabled(for display: DisplayInfo) -> Bool {
        guard let d = mpDisplay(for: display.displayID) else { return false }
        return (d.value(forKey: "preferHDRModes") as? Bool) == true
    }

    /// Newest HDR-preference request per display. An off request waits out
    /// the boost collapse before switching modes; if a newer request lands
    /// during that wait, the older one must not fire its stale mode switch
    /// afterward (a fast off-then-on flip would otherwise end on SDR half a
    /// second after the user chose HDR).
    private var hdrRequestGeneration: [CGDirectDisplayID: Int] = [:]

    /// Explicit HDR on/off for a display. Turning off while boost is enabled
    /// for it first runs boost's own disable-collapse to completion (waiting
    /// out collapsingDisplays, then a short settle) so brightness is back at
    /// 100 before the mode switch, instead of the collapse animation fighting
    /// an SDR display underneath it.
    @discardableResult
    func setHDRPreference(_ on: Bool, for display: DisplayInfo) async -> Bool {
        let displayID = display.displayID
        let generation = (hdrRequestGeneration[displayID] ?? 0) + 1
        hdrRequestGeneration[displayID] = generation
        if on {
            return setHDRMode(true, for: displayID)
        }
        if isEnabled(for: display) {
            _ = await setEnabled(false, for: display)
        }
        // Wait on the live collapse set, not the isEnabled flag: a collapse
        // started moments earlier from the Extra Brightness row has already
        // cleared the flag but is still animating this display.
        while collapsingDisplays.contains(displayID) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Brief settle so the collapse's last brightness write lands
        // before the mode switch.
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard hdrRequestGeneration[displayID] == generation else { return false }
        return setHDRMode(false, for: displayID)
    }

    // MARK: - MonitorPanel HDR mode (private API; selectors verified by the Task 1 spike)

    private func mpDisplay(for displayID: CGDirectDisplayID) -> NSObject? {
        guard let displays = manager?.value(forKey: "displays") as? [NSObject] else { return nil }
        return displays.first { ($0.value(forKey: "displayID") as? UInt32) == displayID }
    }

    /// Hardware capability, cached per displayID: the MPDisplay read is a
    /// synchronous WindowServer round-trip (SLSDisplaySupportsHDRMode), and
    /// HDRToggleView's body hits this on every render, 125x/s during a
    /// brightness glide. The cache clears on screen reconfiguration, the only
    /// time capability (or displayID assignment) can change.
    private var hdrSupportCache: [CGDirectDisplayID: Bool] = [:]

    private func supportsHDRMode(_ displayID: CGDirectDisplayID) -> Bool {
        if let cached = hdrSupportCache[displayID] { return cached }
        guard let d = mpDisplay(for: displayID) else { return false }
        let supported = (d.value(forKey: "hasHDRModes") as? Bool) == true
        hdrSupportCache[displayID] = supported
        return supported
    }

    @discardableResult
    private func setHDRMode(_ on: Bool, for displayID: CGDirectDisplayID) -> Bool {
        guard let d = mpDisplay(for: displayID) else { return false }
        let sel = NSSelectorFromString("setPreferHDRModes:")
        guard d.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(d.method(for: sel), to: Fn.self)(d, sel, on)
        BrightnessService.shared.setHDRSoftwareDimming(on, for: displayID)
        return true
    }

    /// Keeps BrightnessService's DDC-vs-software routing in step with each
    /// external's live HDR mode. A DisplayHDR monitor owns its luminance and
    /// silently discards DDC brightness writes (they still ack), so the whole
    /// 0-100 range must dim in software while HDR is on. Covers HDR changes
    /// made outside Crisp (System Settings): every HDR flip fires a screen
    /// reconfiguration, which lands here via reapplyAll.
    private func syncHDRRouting() {
        // Every external gets an explicit answer, not just HDR-eligible ones:
        // a display inheriting a reused ID from a disconnected HDR display
        // must be actively cleared out of the software-dimming set, or its
        // DDC control stays silently routed to gamma.
        for display in DisplayManagerAccessor.shared.displays where !display.isBuiltin {
            let dimmed = isEligibleForHDRToggle(display) && isHDREnabled(for: display)
            BrightnessService.shared.setHDRSoftwareDimming(dimmed, for: display.displayID)
        }
    }
}
