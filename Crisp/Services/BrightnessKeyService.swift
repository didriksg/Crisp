import AppKit
import CoreGraphics
import ApplicationServices
import os.log

// MARK: - C Event Tap Callback

/// Global C callback for the CGEventTap. `userInfo` carries an Unmanaged<BrightnessKeyService>.
/// The tap is registered on the main run loop, so this callback always fires on the main thread.
private func brightnessKeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let service = Unmanaged<BrightnessKeyService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handleEventFromCallback(type: type, event: event)
}

// MARK: - BrightnessKeyService

/// Intercepts macOS brightness keys and routes them to the display under the mouse cursor.
/// When the cursor is on an external display the key event is consumed and the external
/// display's brightness is adjusted via BrightnessService. When the cursor is on the
/// built-in display the event is passed through so macOS adjusts it normally.
/// Also intercepts the volume/mute keys when the default audio output is a monitor with
/// DDC speaker volume, routing them to VolumeService (see routeVolumePress).
@MainActor
final class BrightnessKeyService: @unchecked Sendable {
    static let shared = BrightnessKeyService()
    private init() {}

    // MARK: - Private State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Retained Unmanaged reference passed into the C callback. Released in stop().
    private var selfRetained: Unmanaged<BrightnessKeyService>?
    /// Monotonic time (systemUptime) of the last tap disable. retryUntilArmed
    /// waits rearmSettleDelay past this before re-arming, to avoid the freeze
    /// a re-arm during an unresolved revoke causes. (kome)
    private var disabledAt: TimeInterval = 0

    // MARK: - NX Media Key Constants
    // `nonisolated` (immutable Sendable constants) so the nonisolated tap
    // callback can read them without hopping to the main actor.

    /// CGEventType raw value for NSSystemDefined / NX_SYSDEFINED events (media keys).
    private nonisolated static let cgEventTypeSystemDefinedRaw: UInt32 = 14
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS, the subtype value for media/function keys.
    private nonisolated static let nxSubtypeAuxControlButtons: Int16 = 8
    /// NX_KEYTYPE_BRIGHTNESS_UP
    private nonisolated static let nxKeytypeBrightnessUp: Int = 2
    /// NX_KEYTYPE_BRIGHTNESS_DOWN
    private nonisolated static let nxKeytypeBrightnessDown: Int = 3
    /// NX_KEYTYPE_SOUND_UP / NX_KEYTYPE_SOUND_DOWN / NX_KEYTYPE_MUTE
    private nonisolated static let nxKeytypeSoundUp: Int = 0
    private nonisolated static let nxKeytypeSoundDown: Int = 1
    private nonisolated static let nxKeytypeMute: Int = 7

    /// Tap lifecycle at notice: #57 lost a round trip on a silently dead tap.
    private nonisolated static let log = Logger(subsystem: "com.crisp.app", category: "keys")

    // MARK: - Start / Stop

    /// Installs the event tap. Requires Accessibility permissions.
    /// Safe to call multiple times, a running tap will not be re-created.
    func start() {
        guard eventTap == nil else { return }

        // Try creating the tap directly, AXIsProcessTrusted can be unreliable
        // with ad-hoc signed Debug builds (TCC entry invalidates after each rebuild).
        let retained = Unmanaged.passRetained(self)
        selfRetained = retained

        // Also tap keyDown (type 10), not just NX_SYSDEFINED. When there is no built-in display to
        // target (e.g. clamshell) macOS can suppress the brightness NX_SYSDEFINED aux event while
        // the raw keyDown still flows, so a SYSDEFINED-only tap goes dead there. See the keyDown
        // fallback in handleEventFromCallback. (issue #21)
        let mask = CGEventMask(1 << Self.cgEventTypeSystemDefinedRaw)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: brightnessKeyEventCallback,
            userInfo: retained.toOpaque()
        )

        guard let tap else {
            retained.release()
            selfRetained = nil
            retryUntilArmed()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        stopRetrying()
        startTrustWatchdog()
        Self.log.notice("key tap armed")
    }

    /// Removes the event tap and releases the retained self reference.
    func stop() {
        stopTrustWatchdog()
        if let tap = eventTap {
            Self.log.notice("key tap removed")
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil

        selfRetained?.release()
        selfRetained = nil
    }

    // MARK: - Accessibility retry
    // No system notification exists for Accessibility-trust changes, so this polls and also
    // retries on app-activation. Do not bound it to a fixed timeout and give up: that leaves
    // the feature dead until an app restart. (b00d.2)

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    private func retryUntilArmed() {
        // ponytail: unbounded 2s poll; tapCreate is cheap and it stops the instant the grant
        // lands. The activation observer just makes it feel instant when the user clicks back in.
        if pollTimer == nil {
            Self.log.notice("key tap refused (Accessibility not granted for this build?), retrying every 2 s")
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                // The timer stays out of the main-actor block below. Handing it in reads as
                // a race even though both halves run on the main run loop.
                guard let self else { timer.invalidate(); return }
                // Scheduled from the main actor, so it fires on the main run loop.
                MainActor.assumeIsolated { self.armIfSettled() }
            }
        }
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.armIfSettled() }
            }
        }
    }

    /// Long enough to outlast the AXIsProcessTrusted()/TCC lag that follows a
    /// revoke; re-arming before that churns and freezes input. (kome)
    private static let rearmSettleDelay: TimeInterval = 3.0

    /// disabledAt is 0 on the initial grant flow, so this arms immediately then.
    private func armIfSettled() {
        guard ProcessInfo.processInfo.systemUptime - disabledAt >= Self.rearmSettleDelay else { return }
        start()
    }

    private func stopRetrying() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
            activationObserver = nil
        }
    }

    // MARK: - Trust watchdog
    // A revoke freezes clicks system-wide for ~1s while WindowServer force-times-out the tap;
    // waiting for that timeout event means waiting through the freeze. So this polls trust
    // faster than that timeout and tears the tap down itself the instant it drops. (kome)

    private var trustWatchdog: Timer?

    private func startTrustWatchdog() {
        guard trustWatchdog == nil else { return }
        // ponytail: 0.5s poll, well inside the ~1s WindowServer tap-timeout; AXIsProcessTrusted()
        // is a cheap TCC lookup so 2x/sec while armed is negligible.
        trustWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            // As with the poll timer, the timer stays out of the main-actor block.
            guard let self else { timer.invalidate(); return }
            // Scheduled from the main actor, so it fires on the main run loop.
            MainActor.assumeIsolated {
                guard self.eventTap != nil, !AXIsProcessTrusted() else { return }
                Self.log.notice("Accessibility trust dropped, tearing the key tap down")
                self.disabledAt = ProcessInfo.processInfo.systemUptime
                self.stop()
                self.retryUntilArmed()
            }
        }
    }

    private func stopTrustWatchdog() {
        trustWatchdog?.invalidate()
        trustWatchdog = nil
    }

    // MARK: - Event Handling
    // Called from the C callback which runs on the main run loop thread.
    // We use nonisolated so Swift 6 doesn't complain about CGEvent (non-Sendable) crossing
    // actor boundaries; all actual state access is done synchronously on the main thread.

    /// Returns nil to consume the event, or a passthrough of `event` to let it
    /// continue. Separated from the callback to keep the C-bridging function minimal.
    nonisolated func handleEventFromCallback(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The system disabled the tap. Never re-enable it here: after a revoke,
        // AXIsProcessTrusted() keeps returning a cached true for a second or
        // two, and re-enabling in that window churns and freezes clicks
        // system-wide. Tear it down instead and let retryUntilArmed re-install
        // it once trust has actually resolved. (kome)
        if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue ||
           type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
            Self.log.notice("key tap disabled by the system (\(type.rawValue == CGEventType.tapDisabledByTimeout.rawValue ? "timeout" : "user input", privacy: .public)), re-arming after settle")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.disabledAt = ProcessInfo.processInfo.systemUptime
                    self.stop()
                    self.retryUntilArmed()
                }
            }
            return Unmanaged.passRetained(event)
        }

        // Fallback: raw keyDown for brightness (144/145). In clamshell mode macOS can suppress
        // the NX_SYSDEFINED aux event while the raw keyDown still flows (issue #21). Third-party
        // keyboards in media-key mode send the pair as F14/F15 (107/113) with no SYSDEFINED
        // event at all (issue #69).
        if type.rawValue == CGEventType.keyDown.rawValue {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            switch kc {
            case 144, 113:
                return routeBrightnessPress(up: true, event: event)
            case 145, 107:
                return routeBrightnessPress(up: false, event: event)
            default:
                return Unmanaged.passRetained(event)
            }
        }

        guard type.rawValue == Self.cgEventTypeSystemDefinedRaw else {
            return Unmanaged.passRetained(event)
        }

        // Convert to NSEvent to inspect media-key subtype.
        guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passRetained(event) }
        guard nsEvent.subtype.rawValue == Self.nxSubtypeAuxControlButtons else {
            return Unmanaged.passRetained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 >> 16) & 0xFF
        let isKeyDown = (data1 & 0x0100) == 0   // bit 8 clear → key down

        switch keyCode {
        case Self.nxKeytypeBrightnessUp, Self.nxKeytypeBrightnessDown:
            // For key-up events always pass through, only consume key-down on external displays.
            guard isKeyDown else { return Unmanaged.passRetained(event) }
            return routeBrightnessPress(up: keyCode == Self.nxKeytypeBrightnessUp, event: event)
        case Self.nxKeytypeSoundUp, Self.nxKeytypeSoundDown, Self.nxKeytypeMute:
            guard isKeyDown else { return Unmanaged.passRetained(event) }
            return routeVolumePress(keyCode: keyCode, event: event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    /// Shared routing for a brightness key-down, from both the media-key and the
    /// raw-keyDown path. Returns nil to consume when we adjusted a display
    /// ourselves, or a pass-through of `event` otherwise.
    nonisolated private func routeBrightnessPress(up: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        let fine = event.flags.contains([.maskAlternate, .maskShift])
        // Explicit targets (allDisplays/selected) win; only underCursor (or a
        // selected set with nothing attached) falls through below. The tap
        // runs on the main run loop, so assumeIsolated is safe here.
        let hasExplicitTargets = MainActor.assumeIsolated { self.explicitTargets() != nil }
        if hasExplicitTargets {
            Task { @MainActor in
                if let targets = self.explicitTargets() { self.adjustDisplays(targets, up: up, fine: fine) }
            }
            // Consume: we adjust every target (built-in included) ourselves, so
            // macOS must not also bump the built-in on top.
            return nil
        }

        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return Unmanaged.passRetained(event)
        }

        // Consume only when we can confirm the cursor is on a live, controllable
        // external display: leaving clamshell briefly leaves NSScreen reporting a
        // stale external Crisp has already dropped, and consuming there swallowed
        // the press (built-in dead until macOS settled, ~30s). Fail safe: pass
        // through if we can't confirm a live external. (issue #12)
        let displayID = screenNumber
        let isControllableExternal = MainActor.assumeIsolated {
            guard let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID })
            else { return false }
            return !display.isBuiltin
        }
        guard isControllableExternal else {
            return Unmanaged.passRetained(event)
        }

        Task { @MainActor in
            let displays = DisplayManagerAccessor.shared.displays
            guard let display = displays.first(where: { $0.displayID == displayID }) else { return }
            self.adjustDisplays([display], up: up, fine: fine)
        }

        // Return nil to consume (suppress) the event so macOS doesn't also adjust built-in brightness.
        return nil
    }

    /// Routes a volume/mute key-down to DDC speaker volume, only when the
    /// default audio output is that monitor (issue #23): HDMI/DP audio has no
    /// macOS volume control otherwise, and any other route passes through.
    nonisolated private func routeVolumePress(keyCode: Int, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Resolved synchronously on the main thread (this tap runs on the main run
        // loop): consume only when a live DDC-volume display owns the audio output.
        let target = MainActor.assumeIsolated {
            VolumeService.shared.displayForDefaultAudioOutput(in: DisplayManagerAccessor.shared.displays)
        }
        guard let target else { return Unmanaged.passRetained(event) }

        // Option+Shift moves a quarter of a stop, the same finer grid the brightness
        // keys use. Read off the event here, where the flags still are.
        let fine = event.flags.contains([.maskAlternate, .maskShift])
        Task { @MainActor in
            let service = VolumeService.shared
            switch keyCode {
            case Self.nxKeytypeMute:
                service.toggleMute(for: target)
            case Self.nxKeytypeSoundUp:
                service.setVolume(BrightnessKeySteps.next(from: target.volume, up: true, fine: fine), for: target)
            default:
                service.setVolume(BrightnessKeySteps.next(from: target.volume, up: false, fine: fine), for: target)
            }
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == target.displayID
            }) {
                BrightnessHUDService.shared.show(
                    level: target.volume,
                    image: target.volume <= 0 ? .mute : .volume,
                    on: screen
                )
            }
        }
        // Consume: macOS must not also show its "no volume control" OSD on top.
        return nil
    }

    /// The Brightness Keys target setting's displays, or nil to leave the
    /// choice to the pointer (underCursor, or a selected set with none
    /// attached, so a press still does something instead of being dead).
    private func explicitTargets() -> [DisplayInfo]? {
        let displays = DisplayManagerAccessor.shared.displays
        switch SettingsService.shared.brightnessKeyTarget {
        case .allDisplays:
            return displays
        case .selected:
            let selected = SettingsService.shared.brightnessKeySelectedDisplayUUIDs
            let targets = displays.filter { selected.contains($0.displayUUID) }
            return targets.isEmpty ? nil : targets
        case .underCursor:
            return nil
        }
    }

    /// Steps brightness for a shortcut bound in Settings > Keyboard Shortcuts
    /// (issue #160), for keyboards whose brightness keys are missing or taken.
    /// Same stops, fades, banner and targets as the keys, except it moves the
    /// built-in itself under the cursor: a shortcut has no event to pass through.
    func adjustFromShortcut(up: Bool) {
        if let targets = explicitTargets() {
            adjustDisplays(targets, up: up)
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID })
        else { return }
        adjustDisplays([display], up: up)
    }

    /// Moves each display to its next stop through BrightnessService's smooth
    /// fade, and shows the HUD. Backs every key mode and the shortcuts; `fine`
    /// is the quarter step Option+Shift asks for (a shortcut always moves a
    /// whole stop).
    @MainActor
    private func adjustDisplays(_ displays: [DisplayInfo], up: Bool, fine: Bool = false) {
        let screens = NSScreen.screens
        for display in displays {
            // Step from the fade's target while one is running, not from the value
            // it is passing through, or a held key never gets past the first stop.
            let from = BrightnessService.shared.inFlightTarget(for: display.displayID) ?? display.brightness
            let newBrightness = max(0.0, min(display.maxBrightness,
                                             BrightnessKeySteps.next(from: from, up: up, fine: fine)))
            BrightnessService.shared.setBrightnessSmooth(newBrightness, for: display)
            if let screen = screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }) {
                BrightnessHUDService.shared.show(brightness: newBrightness / display.maxBrightness * 100.0, on: screen)
            }
        }
    }
}
