import AppKit
import CoreGraphics
import ApplicationServices

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
    /// Monotonic time (systemUptime) of the last tap disable. retryUntilArmed waits a short
    /// settle delay past this before re-arming, so a revoke (whose trust state briefly lags)
    /// resolves before we put an active session tap back in the pipeline. Avoids the kome
    /// input-freeze churn.
    private var disabledAt: TimeInterval = 0

    // MARK: - NX Media Key Constants
    // Read from the nonisolated callback method; immutable Sendable `static let`s
    // are implicitly nonisolated, so that is safe without any annotation.

    /// CGEventType raw value for NSSystemDefined / NX_SYSDEFINED events (media keys).
    private static let cgEventTypeSystemDefinedRaw: UInt32 = 14
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS, the subtype value for media/function keys.
    private static let nxSubtypeAuxControlButtons: Int16 = 8
    /// NX_KEYTYPE_BRIGHTNESS_UP
    private static let nxKeytypeBrightnessUp: Int = 2
    /// NX_KEYTYPE_BRIGHTNESS_DOWN
    private static let nxKeytypeBrightnessDown: Int = 3
    /// NX_KEYTYPE_SOUND_UP / NX_KEYTYPE_SOUND_DOWN / NX_KEYTYPE_MUTE
    private static let nxKeytypeSoundUp: Int = 0
    private static let nxKeytypeSoundDown: Int = 1
    private static let nxKeytypeMute: Int = 7

    /// Each key press moves brightness by 1/16 (≈ 6.25 %), matching macOS native behaviour.
    private static let brightnessStep: Double = 100.0 / 16.0
    /// Volume keys use the same 1/16 step as macOS's own volume control.
    private static let volumeStep: Double = 100.0 / 16.0

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
    }

    /// Removes the event tap and releases the retained self reference.
    func stop() {
        stopTrustWatchdog()
        if let tap = eventTap {
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
    // There is no system notification for Accessibility-trust changes, so we keep trying to
    // arm the tap on two triggers until it takes: a slow recurring poll (reliable) and
    // app-activation (fast path when the user returns from System Settings after granting).
    // Whichever arms the tap calls stopRetrying(). This replaces the old bounded 30s give-up
    // that left the feature dead until an app restart. (b00d.2)

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    private func retryUntilArmed() {
        // ponytail: unbounded 2s poll; tapCreate is cheap and it stops the instant the grant
        // lands. The activation observer just makes it feel instant when the user clicks back in.
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.armIfSettled()
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

    /// How long to wait after a tap disable before trying to re-arm, so an Accessibility revoke
    /// has fully resolved before we put an active session tap back in the pipeline. Long enough
    /// to outlast the AXIsProcessTrusted()/TCC lag that follows a revoke. (kome)
    private static let rearmSettleDelay: TimeInterval = 3.0

    /// Re-arm the tap, but not until any recent disable has had time to settle. Re-creating an
    /// active session tap while a revoke is still propagating is exactly what churns and freezes
    /// input; once settled, tapCreate cleanly succeeds (still granted) or fails (revoked). On the
    /// initial grant flow disabledAt is 0, so this arms immediately with no delay.
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
    // The freeze on an Accessibility revoke is the WindowServer holding the event stream for
    // ~1s while it force-times-out our now-untrusted active session tap. Our own teardown is
    // instant, but it only runs after that timeout event reaches us, i.e. after the freeze. So
    // while armed we poll trust faster than that ~1s timeout and, the instant it drops, tear our
    // tap out ourselves so the WindowServer has nothing doomed to wait on. (kome)

    private var trustWatchdog: Timer?

    private func startTrustWatchdog() {
        guard trustWatchdog == nil else { return }
        // ponytail: 0.5s poll, well inside the ~1s WindowServer tap-timeout; AXIsProcessTrusted()
        // is a cheap TCC lookup so 2x/sec while armed is negligible.
        trustWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.eventTap != nil, !AXIsProcessTrusted() else { return }
            self.disabledAt = ProcessInfo.processInfo.systemUptime
            self.stop()
            self.retryUntilArmed()
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

    /// Returns `false` to pass the event through, `true` to consume it.
    /// Separated from the callback to keep the C-bridging function minimal.
    nonisolated func handleEventFromCallback(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The system disabled the tap. Never re-enable it here. When the user revokes
        // Accessibility (unchecks Crisp under Privacy > Accessibility) the system force-disables
        // the tap, but AXIsProcessTrusted() keeps returning a cached `true` for a second or two.
        // So any "re-enable while still trusted" (or eager re-create) churns against that
        // force-disable for the whole lag window, and an active .cgSessionEventTap stuck in that
        // loop stalls the window-server input pipeline and freezes clicks system-wide. Instead
        // tear the tap fully out of the run loop at once, which frees input immediately, and let
        // retryUntilArmed re-install it after a short settle delay, once trust has actually
        // resolved (tapCreate then cleanly succeeds if still granted, or fails if revoked). A
        // genuine timeout (rare, only if the main thread stalled past ~1s) recovers the same way,
        // just a few seconds later, without ever risking the freeze. (kome)
        if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue ||
           type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.disabledAt = ProcessInfo.processInfo.systemUptime
                    self.stop()
                    self.retryUntilArmed()
                }
            }
            return Unmanaged.passRetained(event)
        }

        // Fallback path: raw keyDown for brightness. macOS normally delivers brightness as an
        // NX_SYSDEFINED aux event (handled below), but when there is no built-in display to target
        // (e.g. clamshell on some macOS versions) it can suppress that event while the raw keyDown
        // still flows. Keycodes 144/145 are the brightness media keys. Mirrors MonitorControl's
        // dual-path capture, which is why it keeps working in clamshell where a SYSDEFINED-only tap
        // goes dead. (issue #21)
        if type.rawValue == CGEventType.keyDown.rawValue {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            switch kc {
            case 144:
                return routeBrightnessPress(up: true, event: event)
            case 145:
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

    /// Shared routing for a brightness key-down, called by both the NX_SYSDEFINED media-key path
    /// and the raw-keyDown fallback path. Applies the step to the configured target(s), shows the
    /// HUD, and returns nil to CONSUME the event when we adjusted an external display (so macOS does
    /// not also bump the built-in), or a pass-through of `event` when we did not handle it (target
    /// not attached / cursor on built-in / no controllable external).
    nonisolated private func routeBrightnessPress(up: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        let step = up ? Self.brightnessStep : -Self.brightnessStep

        // Route by user preference. Read on the main actor, this callback runs on
        // the main run loop (see class docs), so assumeIsolated is safe here.
        switch MainActor.assumeIsolated({ SettingsService.shared.brightnessKeyTarget }) {
        case .allDisplays:
            Task { @MainActor in self.adjustDisplays(DisplayManagerAccessor.shared.displays, step: step) }
            // Consume: we adjust every display (built-in included) ourselves, so
            // macOS must not also bump the built-in on top.
            return nil
        case .selected:
            // Adjust only the chosen displays that are currently attached. If none
            // are attached, fall through to the under-cursor path so the key still
            // does something instead of being dead.
            let selected = MainActor.assumeIsolated { SettingsService.shared.brightnessKeySelectedDisplayUUIDs }
            let anyAttached = MainActor.assumeIsolated {
                DisplayManagerAccessor.shared.displays.contains { selected.contains($0.displayUUID) }
            }
            if anyAttached {
                Task { @MainActor in
                    let targets = DisplayManagerAccessor.shared.displays.filter { selected.contains($0.displayUUID) }
                    self.adjustDisplays(targets, step: step)
                }
                return nil
            }
        case .underCursor:
            break
        }
        // .underCursor (or .selected with none of the chosen displays attached):
        // fall through to the under-cursor path below.

        // Determine which display is under the cursor.
        // NSEvent.mouseLocation and NSScreen.screens are safe to call on the main thread.
        // The tap runs on the main run loop so this is fine.
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return Unmanaged.passRetained(event)
        }

        // Consume the key ONLY when we can synchronously confirm the cursor is on a
        // currently-connected, controllable EXTERNAL display. Leaving clamshell mode
        // (external unplugged, then lid opened) briefly leaves NSScreen reporting a
        // stale external screen while Crisp's display list has already dropped it. The
        // old code consumed the key on that stale screen, then no-op'd asynchronously on
        // the vanished display, swallowing the press so the built-in stayed dead until
        // macOS settled (~30s). Fail safe instead: if we can't confirm a live external,
        // pass the key through so macOS drives the built-in immediately. (issue #12)
        let displayID = screenNumber
        let isControllableExternal = MainActor.assumeIsolated {
            guard let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID })
            else { return false }
            return !display.isBuiltin
        }
        guard isControllableExternal else {
            return Unmanaged.passRetained(event)
        }

        // All data captured here is Sendable (CGDirectDisplayID = UInt32, Double).
        Task { @MainActor in
            let displays = DisplayManagerAccessor.shared.displays
            guard let display = displays.first(where: { $0.displayID == displayID }) else { return }
            let newBrightness = max(0.0, min(display.maxBrightness, display.brightness + step))
            // Use smooth animation, cancels any in-progress animation automatically.
            BrightnessService.shared.setBrightnessSmooth(newBrightness, for: display)

            // Show OSD on the external display where brightness was adjusted.
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
            }) {
                BrightnessHUDService.shared.show(brightness: newBrightness / display.maxBrightness * 100.0, on: screen)
            }
        }

        // Return nil to consume (suppress) the event so macOS doesn't also adjust built-in brightness.
        return nil
    }

    /// Routes a volume/mute key-down to the monitor's DDC speaker volume, but ONLY
    /// when the default audio output IS that monitor (issue #23). HDMI/DP audio has
    /// no macOS volume control, so without this the system just shows the crossed-out
    /// OSD; any other audio route passes through untouched, macOS keeps owning it.
    nonisolated private func routeVolumePress(keyCode: Int, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Resolved synchronously on the main thread (this tap runs on the main run
        // loop): consume only when a live DDC-volume display owns the audio output.
        let target = MainActor.assumeIsolated {
            VolumeService.shared.displayForDefaultAudioOutput(in: DisplayManagerAccessor.shared.displays)
        }
        guard let target else { return Unmanaged.passRetained(event) }

        Task { @MainActor in
            let service = VolumeService.shared
            switch keyCode {
            case Self.nxKeytypeMute:
                service.toggleMute(for: target)
            case Self.nxKeytypeSoundUp:
                service.setVolume(target.volume + Self.volumeStep, for: target)
            default:
                service.setVolume(target.volume - Self.volumeStep, for: target)
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

    /// Applies the same relative step to each given display (built-in or external),
    /// through BrightnessService's smooth fade (reusing its DDC/gamma/IOKit paths +
    /// coalescing), and shows the brightness HUD on each display's own screen.
    /// Backs the `.allDisplays` and `.selected` brightness-key modes.
    @MainActor
    private func adjustDisplays(_ displays: [DisplayInfo], step: Double) {
        let screens = NSScreen.screens
        for display in displays {
            let newBrightness = max(0.0, min(display.maxBrightness, display.brightness + step))
            BrightnessService.shared.setBrightnessSmooth(newBrightness, for: display)
            if let screen = screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }) {
                BrightnessHUDService.shared.show(brightness: newBrightness / display.maxBrightness * 100.0, on: screen)
            }
        }
    }
}
