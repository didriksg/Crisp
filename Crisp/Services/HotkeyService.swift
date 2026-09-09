import AppKit
import Carbon.HIToolbox
import os.log

/// Registers all of Crisp's global shortcuts via Carbon RegisterEventHotKey and dispatches presses to their actions (issue #61).
///
/// Uses Carbon RegisterEventHotKey, which works in an LSUIElement app with no
/// Accessibility permission (unlike the CGEventTap the brightness keys need) and
/// fires regardless of which app has focus.
@MainActor
final class HotkeyService {
    static let shared = HotkeyService()
    private init() {}

    private static let log = Logger(subsystem: "com.crisp.app", category: "hotkey")

    /// What a registered hotkey triggers.
    private enum Target {
        case preset(UUID)
        case hidpiToggle
        case brightness(up: Bool)
    }

    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef, target: Target)] = [:]
    /// Monotonic id source for EventHotKeyID.id; presses look the id up in
    /// `registrations`, so stale ids from a previous sync simply miss.
    private var nextID: UInt32 = 1
    /// Number of recorders currently suspending registration; while nonzero,
    /// syncRegistrations() registers nothing, so a recorder can capture any
    /// combo, including ones currently bound. A count, not a Bool: two recorder
    /// rows can briefly overlap during a takeover, and SwiftUI may deliver one
    /// row's stop after the other row's start, so a Bool would re-arm every
    /// hotkey while the second row still records.
    private var suspensions = 0

    /// Held-down repeat for the brightness shortcuts. Carbon hotkeys fire once per
    /// press and never repeat, where the brightness keys step for as long as they
    /// are held, so the repeat is ours to run: kEventHotKeyReleased stops it.
    private var repeatTimer: Timer?
    /// Stops the repeat even if a release never arrives (another app taking the
    /// combo, the modifier going up first). Well past a full sweep of the sixteen
    /// stops at any system repeat rate.
    private static let repeatCeiling: TimeInterval = 5.0

    func beginSuspension() {
        suspensions += 1
        syncRegistrations()
    }

    func endSuspension() {
        suspensions = max(0, suspensions - 1)
        syncRegistrations()
    }

    /// Rebuilds every registration from current state: one hotkey per preset
    /// with a shortcut, plus the static Toggle HiDPI action. Idempotent; called
    /// from launch, PresetService.savePresets(), and the recorder.
    func syncRegistrations() {
        for reg in registrations.values { UnregisterEventHotKey(reg.ref) }
        registrations = [:]
        guard suspensions == 0 else {
            Self.log.info("synced: suspended (\(self.suspensions) recorder(s)), nothing registered")
            return
        }
        for preset in PresetService.shared.presets {
            if let shortcut = preset.shortcut { register(shortcut, for: .preset(preset.id)) }
        }
        if let shortcut = SettingsService.shared.hidpiShortcut {
            register(shortcut, for: .hidpiToggle)
        }
        if let shortcut = SettingsService.shared.brightnessUpShortcut {
            register(shortcut, for: .brightness(up: true))
        }
        if let shortcut = SettingsService.shared.brightnessDownShortcut {
            register(shortcut, for: .brightness(up: false))
        }
        Self.log.info("synced: \(self.registrations.count) hotkey(s) registered")
    }

    private func register(_ shortcut: KeyboardShortcut, for target: Target) {
        installHandlerIfNeeded()
        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4372_7370), id: id)  // "Crsp"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        if let ref {
            registrations[id] = (ref, target)
        } else {
            Self.log.error("RegisterEventHotKey failed (status \(status)) for \(shortcut.display, privacy: .public)")
        }
    }

    /// One process-wide handler; events carry the EventHotKeyID that fired. Both
    /// kinds are watched: a press runs the action, a release ends a held brightness
    /// repeat.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            // C-function callback, no captures; read which hotkey fired, then
            // hop to the main actor for the action.
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            Task { @MainActor in
                if pressed {
                    HotkeyService.shared.fire(id: id)
                } else {
                    HotkeyService.shared.releaseHeld(id: id)
                }
            }
            return noErr
        }, eventTypes.count, &eventTypes, nil, &handlerRef)
        if status != noErr { Self.log.error("InstallEventHandler failed (status \(status))") }
    }

    private func fire(id: UInt32) {
        Self.log.info("hotkey press: id \(id), known=\(self.registrations[id] != nil)")
        switch registrations[id]?.target {
        case .preset(let presetID):
            // Same guards as tapping the preset row: no-op while one applies or
            // when this preset is already the active (checkmarked) one, so a
            // repeat press doesn't re-apply and jiggle the row.
            guard let preset = PresetService.shared.presets.first(where: { $0.id == presetID }),
                  !PresetService.shared.isApplying,
                  PresetService.shared.activePresetID != presetID
            else { return }
            Task { await PresetService.shared.applyPreset(preset) }
        case .hidpiToggle:
            toggleHiDPIUnderCursor()
        case .brightness(let up):
            BrightnessKeyService.shared.adjustFromShortcut(up: up)
            startRepeat(up: up)
        case nil:
            break
        }
    }

    /// A hotkey came back up. Only the brightness shortcuts repeat, so only they
    /// have something to stop; a preset shortcut released while brightness is held
    /// must not cut that repeat short.
    private func releaseHeld(id: UInt32) {
        if case .brightness = registrations[id]?.target { stopRepeat() }
    }

    /// Keeps stepping while the shortcut is held, after the system's own repeat
    /// delay and at the system's own rate, so it feels like a held brightness key.
    private func startRepeat(up: Bool) {
        stopRepeat()
        let deadline = Date().addingTimeInterval(Self.repeatCeiling)
        let timer = Timer(fire: Date().addingTimeInterval(NSEvent.keyRepeatDelay),
                          interval: NSEvent.keyRepeatInterval,
                          repeats: true) { timer in
            // Added to the main run loop below, so it fires on the main actor.
            MainActor.assumeIsolated {
                guard Date() < deadline else { timer.invalidate(); return }
                BrightnessKeyService.shared.adjustFromShortcut(up: up)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: - Action

    /// Flips the display under the pointer between the HiDPI and low-resolution
    /// variant of its current logical size: an instant mode switch, same as picking
    /// the twin row in the Resolution list (no override plist, no reconnect).
    /// Under-cursor targeting matches the brightness keys (BrightnessKeyService).
    func toggleHiDPIUnderCursor() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID }),
              let current = display.currentDisplayMode,
              let target = Self.hiDPITwin(of: current, in: display.availableModes)
        else {
            // No twin at this size (or the display vanished): audible no-op instead of
            // a shortcut that silently does nothing.
            Self.log.info("hidpi toggle: no twin under pointer, beeping")
            NSSound.beep()
            return
        }
        Self.log.info("hidpi toggle: switching display \(displayID) to \(target.width)x\(target.height) hidpi=\(target.isHiDPI)")
        Task { @MainActor in
            _ = await ResolutionService.shared.setDisplayMode(target, for: displayID)
        }
    }

    /// Same logical size, opposite scaling; keeps the current refresh rate when the
    /// twin offers it (tolerant match, CG reports fractional rates), else the
    /// highest-refresh twin.
    static func hiDPITwin(of current: DisplayMode, in modes: [DisplayMode]) -> DisplayMode? {
        let twins = modes.filter {
            $0.width == current.width && $0.height == current.height && $0.isHiDPI != current.isHiDPI
        }
        return twins.first { ResolutionService.refreshMatches($0.refreshRate, current.refreshRate) }
            ?? twins.max { $0.refreshRate < $1.refreshRate }
    }
}
