import Foundation
import IOKit
import CoreGraphics

// DisplayServices private API, reads the builtin display's actual brightness
// (0.0–1.0), the value the slider/keys/ambient sensor move. Primary read path:
// CoreDisplay_Display_GetUserBrightness is pinned at 1.0 on macOS 26 (probe:
// slider changes moved DisplayServices 0.97→0.72 while CoreDisplay stayed 1.0).
private let _DisplayServices_GetBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
}()
// CoreDisplay private API, reads the user-set brightness of a display (0.0–1.0).
// Loaded via dlsym at runtime to avoid linking against the private CoreDisplay framework.
private let _CoreDisplay_GetBrightness: (@convention(c) (CGDirectDisplayID) -> Double)? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "CoreDisplay_Display_GetUserBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID) -> Double).self)
}()

/// Reads the built-in display's brightness (which macOS auto-adjusts based on ambient light)
/// and syncs it to external displays. This avoids needing Intel-only LMU hardware access.
@MainActor
final class AutoBrightnessService: ObservableObject, @unchecked Sendable {
    static let shared = AutoBrightnessService()
    private init() {
        loadPrefs()
    }

    // MARK: - State

    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                // Pin offsets from the current levels so enabling holds them (no snap).
                needsRebaseline = true
                startPolling()
            } else {
                stopPolling()
            }
            savePrefs()
        }
    }

    /// Multiplier 0.5–1.5. Applied to builtin brightness when syncing to external displays.
    @Published var sensitivity: Double = 1.0 {
        didSet { savePrefs() }
    }

    /// When true (default), externals keep the offset the user set relative to the built-in
    /// and ride its changes; when false they mirror the built-in's absolute level (old
    /// behavior). Toggling on re-pins offsets from the current levels.
    @Published var relativeMode: Bool = true {
        didSet {
            if relativeMode { needsRebaseline = true }
            savePrefs()
            // Re-aim externals immediately on a user toggle instead of waiting for the
            // next built-in change: disabling snaps them to the built-in's level, enabling
            // re-pins offsets from the current levels (no movement).
            if isEnabled && !isLoadingPrefs {
                Task { @MainActor in
                    await applyBrightness(builtin: readBuiltinBrightness(), force: true)
                }
            }
        }
    }

    /// Last builtin brightness reading (0.0–1.0). 0 = unavailable / no builtin display.
    @Published private(set) var builtinBrightness: Double = 0
    private var lastAppliedBrightness: Double = -1

    /// Per-display brightness offset from the built-in (percent = external - builtin),
    /// captured while tracking; relative mode drives externals to builtin% + offset.
    /// In-memory only; re-pinned on enable. Kept across disconnects on purpose so a
    /// reconnected monitor gets the user's preferred offset back.
    private var offsets: [CGDirectDisplayID: Double] = [:]
    /// Set when tracking (re)starts (enable, or toggling relative on) so the next apply
    /// re-pins offsets from the current levels instead of moving anything.
    private var needsRebaseline = false
    /// Last manual external-brightness adjustment. Absolute mode has no offset
    /// re-pinning, so a 30s grace keeps auto-sync from fighting the user's hand
    /// on the slider; the eventual re-sync is that mode's contract.
    private var lastExternalManualAdjust: Date?

    /// Set to true after the first poll attempt completes (success or failure).
    /// Used by the UI to distinguish "not polled yet" from "no builtin display found".
    @Published private(set) var hasPolled: Bool = false

    // MARK: - Private

    private var pollingTask: Task<Void, Never>?
    private let pollingInterval: TimeInterval = 2.0  // seconds
    /// Observes live built-in brightness pushes so externals sync the instant the
    /// built-in moves; the 2s poll stays on as a fallback heartbeat.
    private var builtinChangeObserver: NSObjectProtocol?
    /// Observes manual external adjustments so we re-pin that display's offset.
    private var externalAdjustObserver: NSObjectProtocol?
    /// Observes manual built-in adjustments so we re-pin offsets (externals hold) instead
    /// of following a deliberate built-in change.
    private var builtinAdjustObserver: NSObjectProtocol?

    // MARK: - Builtin Brightness

    /// Reads the current brightness of the builtin display.
    /// Returns a value in 0.0–1.0, or nil if no builtin display is found.
    /// Safe to call from a background thread.
    nonisolated func readBuiltinBrightness() -> Double? {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        guard let builtinID = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            return nil
        }

        // DisplayServices first: the only API that tracks the real brightness here.
        // Trust its success code (== 0) and accept a value of 0 as a genuinely dark panel.
        // Do NOT additionally require dsValue > 0 and fall through on a dark/failed read:
        // the CoreDisplay fallback below is pinned at 1.0 on macOS 26, so falling through
        // reported a bogus 100% and flipped externals UP to (100 - offset) when the built-in
        // bottomed out. If DisplayServices is present but the read fails, report unavailable
        // (nil) so externals hold, rather than emitting that bogus full-brightness reading.
        if let getBrightness = _DisplayServices_GetBrightness {
            var dsValue: Float = 0
            guard getBrightness(builtinID, &dsValue) == 0 else { return nil }
            return min(1.0, max(0.0, Double(dsValue)))
        }

        // Fallback: CoreDisplay (stale on macOS 26, may work on older systems).
        let value = _CoreDisplay_GetBrightness?(builtinID) ?? 0
        if value > 0 {
            return min(1.0, max(0.0, value))
        }

        // Fallback: IODisplayGetFloatParameter via IOKit service matching
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }
        var service = IOIteratorNext(iter)
        while service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            var floatValue: Float = 0
            let kr = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &floatValue)
            if kr == KERN_SUCCESS && floatValue > 0 {
                return min(1.0, max(0.0, Double(floatValue)))
            }
        }

        return nil
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollingTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let brightness = self.readBuiltinBrightness()
                await self.applyBrightness(builtin: brightness)
                try? await Task.sleep(nanoseconds: UInt64(self.pollingInterval * 1_000_000_000))
            }
        }
        // Sync externals the moment the built-in changes, so they don't trail the 2s poll.
        builtinChangeObserver = NotificationCenter.default.addObserver(
            forName: .crispBuiltinBrightnessDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isEnabled else { return }
                await self.applyBrightness(builtin: self.readBuiltinBrightness())
            }
        }
        // Re-pin a display's offset when the user manually adjusts it, so relative mode
        // holds their chosen level instead of overriding it after the cooldown.
        // Synchronous (queue nil, on the posting thread) so the offset lands before any
        // apply can use a stale one, that race is what the 30s cooldown used to mask.
        externalAdjustObserver = NotificationCenter.default.addObserver(
            forName: .crispExternalManualAdjust, object: nil, queue: nil
        ) { [weak self] note in
            guard let self,
                  let id = note.userInfo?["displayID"] as? CGDirectDisplayID,
                  let value = note.userInfo?["value"] as? Double else { return }
            MainActor.assumeIsolated {
                guard self.isEnabled else { return }
                self.lastExternalManualAdjust = Date()
                guard self.relativeMode else { return }
                let builtinPct = (self.readBuiltinBrightness() ?? self.builtinBrightness) * 100.0
                self.offsets[id] = value - builtinPct
            }
        }
        // A manual built-in change is the user's intent, not the ambient signal. Re-pin
        // offsets so externals hold and the offset absorbs the change. Set synchronously
        // (queue nil, on the posting thread) so it lands before the built-in subscription's
        // apply runs and drags the externals.
        builtinAdjustObserver = NotificationCenter.default.addObserver(
            forName: .crispBuiltinManualAdjust, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isEnabled, self.relativeMode else { return }
                self.needsRebaseline = true
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        if let obs = builtinChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            builtinChangeObserver = nil
        }
        if let obs = externalAdjustObserver {
            NotificationCenter.default.removeObserver(obs)
            externalAdjustObserver = nil
        }
        if let obs = builtinAdjustObserver {
            NotificationCenter.default.removeObserver(obs)
            builtinAdjustObserver = nil
        }
    }

    @MainActor
    private func applyBrightness(builtin: Double?, force: Bool = false) async {
        builtinBrightness = builtin ?? 0
        hasPolled = true

        guard let builtin, builtin > 0 else { return }

        // Only apply if builtin brightness changed more than 2% since last application,
        // unless forced (the user just flipped relative<->absolute, so externals must
        // re-aim now instead of waiting for the next built-in change).
        guard force || abs(builtin - lastAppliedBrightness) >= 0.02 else { return }

        // Absolute mode: a fresh manual external adjustment wins for 30s (relative mode
        // absorbs it into the offset instead). A forced apply is a deliberate mode
        // toggle, so it bypasses the grace.
        if !force, !relativeMode, let last = lastExternalManualAdjust,
           Date().timeIntervalSince(last) < 30 { return }

        let builtinPct = builtin * 100.0
        // In relative mode, (re)pin offsets from the current levels on the first apply
        // after tracking (re)starts, so nothing snaps; afterwards just ride the built-in.
        let rebaselineNow = relativeMode && needsRebaseline
        needsRebaseline = false

        let snapshot = DisplayManagerAccessor.shared.displays
        let builtinDisplay = snapshot.first(where: { $0.isBuiltin })
        let builtinLinear = builtinDisplay.flatMap {
            BrightnessService.shared.linearBrightness(for: $0.displayID)
        }
        for display in snapshot {
            // Only sync to external (non-builtin) displays.
            guard !display.isBuiltin else { continue }

            let target: Double
            if relativeMode {
                // Pin the offset on rebaseline or first sight of this display; then the
                // external holds the user's chosen gap and follows the built-in's changes.
                if rebaselineNow || offsets[display.displayID] == nil {
                    offsets[display.displayID] = display.brightness - builtinPct
                }
                let offset = offsets[display.displayID] ?? 0
                // Clamp to the display's own ceiling, not a literal 100: while
                // Extra Brightness is on, the pinned offset can place the target
                // in the boost region, and capping at 100 would silently drag a
                // boosted display back down on every built-in change.
                target = min(display.maxBrightness, max(0.0, builtinPct + offset))
            } else if let builtinLinear,
                      let builtinMaxNits = builtinDisplay?.nominalMaxNits,
                      let externalMaxNits = display.nominalMaxNits {
                // Absolute means absolute luminance, not equal slider percentages.
                // The built-in curve is highly nonlinear, so derive DDC percent
                // from estimated nits using the same calibration as Combined.
                let matched = CombinedBrightnessMath.externalBrightnessMatchingBuiltin(
                    builtinLinear: builtinLinear,
                    builtinMaxNits: builtinMaxNits,
                    externalMaxNits: externalMaxNits,
                    builtinAdjustment: SettingsService.shared.combinedBuiltinBrightnessFactor)
                target = min(100.0, max(0.0, matched * sensitivity))
            } else {
                // Missing luminance metadata: preserve the old percentage mirror.
                target = min(100.0, max(0.0, builtin * sensitivity * 100.0))
            }

            let current = display.brightness
            if abs(current - target) >= 2.0 {
                // Short glide, just enough to smooth the DDC steps (~0.4s is about the
                // DDC write floor). The built-in subscription re-aims this continuously
                // as the panel moves, so the stream of updates is the motion; the old
                // 1.6s (tuned for the 2s poll) just made the external trail the built-in.
                BrightnessService.shared.setBrightnessSmooth(
                    target, for: display, isAutoAdjust: true, duration: 0.4)
            }
        }
        lastAppliedBrightness = builtin
    }

    // MARK: - Persistence

    private let enabledKey = "crisp.AutoBrightnessEnabled"
    private let sensitivityKey = "crisp.AutoBrightnessSensitivity"
    private let relativeKey = "crisp.AutoBrightnessRelative"
    /// Guards savePrefs during loadPrefs: assigning one property fires its didSet, which
    /// would otherwise write the other, not-yet-loaded defaults over their stored values.
    private var isLoadingPrefs = false

    private func loadPrefs() {
        isLoadingPrefs = true
        defer { isLoadingPrefs = false }
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        if UserDefaults.standard.object(forKey: sensitivityKey) != nil {
            sensitivity = UserDefaults.standard.double(forKey: sensitivityKey)
        }
        if UserDefaults.standard.object(forKey: relativeKey) != nil {
            relativeMode = UserDefaults.standard.bool(forKey: relativeKey)
        } else if UserDefaults.standard.object(forKey: enabledKey) != nil {
            // Upgrade migration: prior installs (enabledKey persisted before relativeMode
            // existed) used Auto Brightness under the absolute-mirror behavior; keep it
            // instead of silently switching them to relative offsets. Fresh installs
            // (no keys at all) keep the relative default.
            relativeMode = false
        }
    }

    private func savePrefs() {
        guard !isLoadingPrefs else { return }
        UserDefaults.standard.set(isEnabled, forKey: enabledKey)
        UserDefaults.standard.set(sensitivity, forKey: sensitivityKey)
        UserDefaults.standard.set(relativeMode, forKey: relativeKey)
    }
}

// MARK: - Display Manager Accessor

/// Thin wrapper so AutoBrightnessService can reach displays without a direct EnvironmentObject.
@MainActor
final class DisplayManagerAccessor {
    static let shared = DisplayManagerAccessor()
    var displays: [DisplayInfo] = []
    private init() {}
}
