import Foundation
import IOKit
import IOKit.graphics
import CoreGraphics
// For CGDisplayCreateUUIDFromDisplayID (ApplicationServices, not CoreGraphics).
import AppKit

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

// DisplayServices private framework, built-in panel brightness on Apple Silicon,
// where IODisplayConnect no longer exists (CoreDisplay_Display_SetUserBrightness
// is also a no-op there). Loaded via dlsym, same pattern as AutoBrightnessService.
private let _DSSetBrightness: (@convention(c) (CGDirectDisplayID, Float) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
}()
private let _DSGetBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
}()
private let _DSSetLinearBrightness: (@convention(c) (CGDirectDisplayID, Float) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesSetLinearBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
}()
private let _DSGetLinearBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesGetLinearBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
}()

// DisplayServices brightness-change notifications: push updates so the UI tracks the
// built-in panel live (native keys, auto-brightness, Night Shift/TrueTone) instead of
// only refreshing on panel-open/wake/reconfigure. Signatures verified against SketchyBar
// (src/misc/extern.h + src/display.c): register(did, passthrough, callback) plus a 5-arg
// callback (passthrough, did, name, sender, info); brightness is not passed, it's read
// back via DisplayServicesGetBrightness.
private typealias DSBrightnessChangeHandler = @convention(c) (
    UnsafeMutableRawPointer?, CGDirectDisplayID,
    UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?
) -> Void

private let _DSRegisterBrightnessChange: (@convention(c) (CGDirectDisplayID, UInt32, DSBrightnessChangeHandler) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesRegisterForBrightnessChangeNotifications") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UInt32, DSBrightnessChangeHandler) -> Int32).self)
}()
private let _DSUnregisterBrightnessChange: (@convention(c) (CGDirectDisplayID, UInt32) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesUnregisterForBrightnessChangeNotifications") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UInt32) -> Int32).self)
}()

/// C callback fired when a display's brightness changes from any source. Brightness is
/// not a parameter (per the reverse-engineered API), so we read it back and push it onto
/// the matching DisplayInfo on the main actor. Must be a capture-free top-level function
/// to be usable as a @convention(c) pointer.
private func _crispBuiltinBrightnessChanged(
    _ passthrough: UnsafeMutableRawPointer?,
    _ did: CGDirectDisplayID,
    _ name: UnsafeMutableRawPointer?,
    _ sender: UnsafeRawPointer?,
    _ info: UnsafeRawPointer?
) {
    guard let get = _DSGetBrightness else { return }
    var v: Float = 0
    guard get(did, &v) == 0 else { return }
    let value = Double(v) * 100.0
    Task { @MainActor in
        guard let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == did })
        else { return }
        guard display.brightness <= 100.0 else { return }
        // Skip sub-0.5% jitter to avoid redundant @Published churn.
        guard abs(display.brightness - value) >= 0.5 else { return }
        display.brightness = value
        // Drive auto-brightness off this live change so external displays follow the
        // built-in immediately instead of trailing its 2s poll. (issue #12 follow-up)
        NotificationCenter.default.post(name: .crispBuiltinBrightnessDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Posted when the built-in display's brightness changes (keys, ambient auto-brightness).
    static let crispBuiltinBrightnessDidChange = Notification.Name("crisp.builtinBrightnessDidChange")
    /// Posted when the user manually changes an EXTERNAL display's brightness (slider, keys,
    /// preset). userInfo: "displayID" (CGDirectDisplayID), "value" (Double, 0–100).
    static let crispExternalManualAdjust = Notification.Name("crisp.externalManualAdjust")
    /// Posted when the user manually changes the BUILT-IN display's brightness from Crisp.
    /// Distinguishes a deliberate built-in change from the ambient signal auto-brightness follows.
    static let crispBuiltinManualAdjust = Notification.Name("crisp.builtinManualAdjust")
}

// MARK: - BrightnessAnimator

/// Manages smooth brightness transitions for a single display.
/// Cancels any in-progress animation when a new one starts, so rapid presses stay responsive.
/// All methods must be called on the main thread.
final class BrightnessAnimator: @unchecked Sendable {
    private var timer: Timer?
    private var currentStep: Int = 0
    private var totalSteps: Int = 0
    private var startValue: Double = 0
    private var targetValue: Double = 0
    private var stepHandler: ((Double, Bool) -> Void)?

    /// Cancel any running animation immediately.
    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// Animate from `from` to `to` over `duration` seconds using `steps` discrete steps.
    /// `handler(value, isLast)` is called once per step on the main thread.
    /// Calling this cancels any previously running animation.
    func animate(
        from: Double,
        to: Double,
        steps: Int,
        duration: TimeInterval,
        handler: @escaping (Double, Bool) -> Void
    ) {
        cancel()

        // If from ≈ to, no animation needed, just apply final value.
        guard abs(to - from) > 0.001, steps > 1 else {
            handler(to, true)
            return
        }

        let clampedSteps = max(2, steps)
        currentStep = 0
        totalSteps = clampedSteps
        startValue = from
        targetValue = to
        stepHandler = handler
        let interval = duration / Double(clampedSteps)

        // .common mode keeps the timer firing during event tracking (menu panel
        // open, scrolling); in .default mode it stalls and the fade looks ~10fps.
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.currentStep += 1
            let progress = Double(self.currentStep) / Double(self.totalSteps)
            // Ease-out curve: smoother deceleration at the end
            let eased = 1.0 - pow(1.0 - progress, 2.0)
            let value = self.startValue + (self.targetValue - self.startValue) * eased
            let isLast = self.currentStep >= self.totalSteps
            if isLast {
                t.invalidate()
                self.timer = nil
            }
            // Always pass the exact target on the last step to avoid floating-point drift.
            self.stepHandler?(isLast ? self.targetValue : value, isLast)
            if isLast { self.stepHandler = nil }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }
}

// MARK: - BrightnessService

final class BrightnessService: @unchecked Sendable {
    static let shared = BrightnessService()
    private init() {}

    private let queue = DispatchQueue(label: "com.crisp.brightness", qos: .userInitiated)

    // MARK: - Per-display Animators (main thread only)

    /// One animator per display. Accessed only on the main thread.
    private var animators: [CGDirectDisplayID: BrightnessAnimator] = [:]

    private func animator(for displayID: CGDirectDisplayID) -> BrightnessAnimator {
        if let existing = animators[displayID] { return existing }
        let a = BrightnessAnimator()
        animators[displayID] = a
        return a
    }

    /// Cancel any running brightness animation for a display.
    /// Call this before starting an instant (non-animated) change.
    @MainActor
    func cancelAnimation(for displayID: CGDirectDisplayID) {
        animators[displayID]?.cancel()
    }

    // MARK: - Manual Adjust Cooldown

    /// Set when the user manually adjusts any display's brightness. The menu panel's
    /// external poll skips for a few seconds after this so it doesn't fight a live drag.
    private(set) var lastManualAdjustDate: Date? = nil
    private let manualAdjustLock = NSLock()

    // MARK: - Software Brightness Factors

    /// Stores the current software brightness factor per display (0.01–1.0).
    private var softwareBrightnessFactors: [CGDirectDisplayID: Double] = [:]
    private let softwareBrightnessLock = NSLock()

    /// UUID-keyed like GammaPersistenceKey (issue #32): displayIDs are reused
    /// across reconnects and reboots, so the old raw-ID key could hand this
    /// display's dimming factor to a different physical display later.
    private func softBrightnessKey(for displayID: CGDirectDisplayID) -> String {
        if let uuid = Self.displayUUIDString(for: displayID) {
            return "crisp.softBrightness.uuid.\(uuid)"
        }
        // UUID lookup failed (display just went offline): legacy raw-ID key.
        return Self.legacySoftBrightnessKey(for: displayID)
    }

    private static func legacySoftBrightnessKey(for displayID: CGDirectDisplayID) -> String {
        "crisp.softBrightness_\(displayID)"
    }

    /// Same primary path as DisplayInfo.displayUUID (CG UUID of an online
    /// display), so both produce identical key strings.
    private static func displayUUIDString(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String?
    }

    /// Moves any legacy, displayID-keyed software-brightness factor onto the
    /// stable UUID key, for every display currently online. Same rules as
    /// GammaService.migrateLegacyStateIfNeeded: repeated calls are no-ops, an
    /// existing UUID entry is never overwritten, and a legacy key with no live
    /// display is left alone (guessing which physical display it belonged to
    /// is exactly the bug being fixed).
    @MainActor
    func migrateLegacySoftBrightnessIfNeeded(for displays: [DisplayInfo]) {
        let defaults = UserDefaults.standard
        for display in displays {
            let legacyKey = Self.legacySoftBrightnessKey(for: display.displayID)
            guard defaults.object(forKey: legacyKey) != nil else { continue }
            let uuidKey = "crisp.softBrightness.uuid.\(display.displayUUID)"
            if defaults.object(forKey: uuidKey) == nil {
                defaults.set(defaults.double(forKey: legacyKey), forKey: uuidKey)
            }
            defaults.removeObject(forKey: legacyKey)
        }
    }

    private func saveSoftwareBrightness(factor: Double, for displayID: CGDirectDisplayID) {
        UserDefaults.standard.set(factor, forKey: softBrightnessKey(for: displayID))
    }

    private func loadSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        let key = softBrightnessKey(for: displayID)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.double(forKey: key)
    }

    /// Returns the current software brightness factor for a display, or nil if not set.
    func currentSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] }
    }

    // MARK: - DDC Availability Cache

    /// Tracks whether hardware DDC is available for each external display.
    /// nil  = not yet determined
    /// true = DDC write succeeded at least once
    /// false = DDC write has failed; use software (gamma) fallback
    private var ddcAvailable: [CGDirectDisplayID: Bool] = [:]
    private let ddcAvailableLock = NSLock()

    /// Per-display DDC max brightness value reported by the monitor.
    /// Used to denormalize 0–100% into the display's native DDC range.
    private var ddcMaxBrightness: [CGDirectDisplayID: UInt16] = [:]

    // MARK: - Public API

    /// Native panel brightness in a linear luminance domain. Multiplying this
    /// by DisplayInfo.nominalMaxNits yields the current estimated nits.
    func linearBrightness(for displayID: CGDirectDisplayID) -> Double? {
        guard let get = _DSGetLinearBrightness else { return nil }
        var value: Float = 0
        guard get(displayID, &value) == 0 else { return nil }
        return min(1.0, max(0.0, Double(value)))
    }

    /// `animated: true` glides the built-in slider to the freshly-read value
    /// instead of snapping, used by the ~1s poll so an ambient-sensor auto-adjust
    /// reads as smooth motion. Instant (default) on load/wake where the slider
    /// should show the real value immediately.
    @MainActor
    func refreshBrightness(for display: DisplayInfo, animated: Bool = false) async {
        // While boosted above 100 the hardware pins at max and reads back ~100;
        // adopting that would snap the slider out of the boost region. Crisp
        // owns the value while Extra Brightness is engaged.
        if display.brightness > 100.0 { return }
        let isBuiltin = display.isBuiltin
        let displayID = display.displayID

        if isBuiltin {
            let brightness = await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    continuation.resume(returning: self?.getInternalBrightness())
                }
            }
            if let b = brightness {
                // macOS already moved the backlight; only the displayed value needs
                // to catch up. Glide it (no hardware write) so the knob doesn't jump
                // between polls. Deadband avoids a perpetual timer on sensor
                // jitter; sub-0.5% moves are imperceptible, so just set them.
                if animated, abs(b - display.brightness) >= 0.5 {
                    animator(for: displayID).animate(
                        from: display.brightness, to: b,
                        steps: max(8, Int(1.0 / 0.008)), duration: 1.0
                    ) { [weak display] value, _ in
                        display?.brightness = value
                    }
                } else {
                    display.brightness = b
                }
            }
        } else {
            // First check if DDC is already known to be unavailable; if so skip the
            // async DDC call and just read the current gamma-derived brightness.
            let knownUnavailable: Bool = ddcAvailableLock.withLock {
                ddcAvailable[displayID] == false
            }
            if knownUnavailable {
                // Can't read brightness from gamma tables meaningfully; leave value as-is
                return
            }

            DDCService.shared.readAsync(
                displayID: displayID,
                command: DDCService.brightnessVCP
            ) { [weak self] result in
                guard let self else { return }
                if let result = result, result.max > 0 {
                    let brightness = Double(result.current) / Double(result.max) * 100.0
                    self.ddcAvailableLock.lock()
                    let firstRead = self.ddcAvailable[displayID] != true
                    self.ddcAvailable[displayID] = true
                    self.ddcMaxBrightness[displayID] = result.max
                    self.ddcAvailableLock.unlock()
                    Task { @MainActor in
                        // DDC reads quantize (many panels expose a coarser internal
                        // scale than they accept), so a value we just set can read back
                        // 1-2% off and twitch the slider on every open. Adopt the read
                        // only on the first seed, or when it differs enough to be a real
                        // external change (the monitor's own buttons), not read noise.
                        if firstRead || abs(brightness - display.brightness) > 3.0 {
                            display.brightness = brightness
                        }
                    }
                }
                // A failed/ignored read does NOT mean DDC is unavailable: many monitors
                // accept brightness *writes* but never answer *reads* (they ack the I2C
                // transaction with stale/null bytes, now rejected by DDCService). Leaving
                // availability undetermined lets the write path decide, marking it false
                // here would wrongly force the gamma/software fallback on a display whose
                // hardware backlight control works fine, just showing a stale slider value.
            }
        }
    }

    /// The built-in display we currently observe for brightness changes.
    private var observedBuiltinID: CGDirectDisplayID?

    /// Subscribes to the built-in panel's brightness-change notifications so the slider
    /// tracks live (native keys, auto-brightness, Night Shift/TrueTone) rather than only
    /// refreshing on panel-open/wake/reconfigure. Idempotent: re-points at the current
    /// built-in (or drops the observer if none) and no-ops when nothing changed, so it's
    /// safe to call on every display reconfiguration.
    @MainActor
    func startObservingBuiltinBrightness() {
        let builtin = builtinDisplayID()
        guard observedBuiltinID != builtin else { return }
        if let old = observedBuiltinID {
            _ = _DSUnregisterBrightnessChange?(old, old)
            observedBuiltinID = nil
        }
        guard let builtin, let register = _DSRegisterBrightnessChange else { return }
        _ = register(builtin, builtin, _crispBuiltinBrightnessChanged)
        observedBuiltinID = builtin
    }

    @MainActor
    func setBrightness(_ brightness: Double, for display: DisplayInfo, isAutoAdjust: Bool = false) async {
        let clamped = max(0.0, min(display.maxBrightness, brightness))
        // Hardware only ever sees 0...100; the region above is the EDR overlay's.
        let hardware = min(clamped, 100.0)
        let isBuiltin = display.isBuiltin
        let displayID = display.displayID

        // A direct manual write wins over any in-flight glide (click fade,
        // step-button glide, refresh catch-up); without this the animator
        // keeps writing stale interpolated values against the drag.
        if !isAutoAdjust {
            cancelAnimation(for: displayID)
        }

        // Record manual adjust time so auto-brightness can honour the cooldown period.
        if !isAutoAdjust {
            manualAdjustLock.withLock {
                lastManualAdjustDate = Date()
            }
            PresetService.shared.noteManualChange()
            noteManualBrightnessChange(displayID: displayID, isBuiltin: isBuiltin, value: clamped)
        }

        if isBuiltin {
            let value = Float(hardware / 100.0)
            display.brightness = clamped
            queue.async { [weak self] in
                self?.setInternalBrightness(value)
            }
        } else {
            display.brightness = clamped
            // In the boost region the external's transfer table belongs to the
            // boost sync below (factor > 1.0); writing the pinned-at-100 dim
            // here too would race it with an identity table on every tick. The
            // monitor is in HDR mode up there anyway, so there is no hardware
            // write to make.
            if clamped <= 100 {
                // Check current DDC availability status
                let currentStatus: Bool? = ddcAvailableLock.withLock { ddcAvailable[displayID] }

                if currentStatus == false {
                    // DDC known unavailable, go straight to software fallback
                    queue.async { [weak self] in
                        self?.setSoftwareBrightness(hardware, for: displayID)
                    }
                } else {
                    writeDDCBrightnessCoalesced(percent: hardware, for: displayID)
                }
            }
        }
        BrightnessBoostService.shared.syncOverlay(for: display)
    }

    /// Broadcasts a manual (user-initiated) brightness change so auto-brightness can react:
    /// an external change re-pins that display's offset; a built-in change re-pins all offsets
    /// (externals hold; the offset absorbs it) instead of dragging the externals along.
    private func noteManualBrightnessChange(displayID: CGDirectDisplayID, isBuiltin: Bool, value: Double) {
        if isBuiltin {
            NotificationCenter.default.post(name: .crispBuiltinManualAdjust, object: nil)
        } else {
            NotificationCenter.default.post(
                name: .crispExternalManualAdjust,
                object: nil,
                userInfo: ["displayID": displayID, "value": value]
            )
        }
    }

    /// Sets a built-in panel in linear luminance space, then reads back the
    /// corresponding native user-slider value so every UI stays truthful.
    @MainActor
    func setBuiltinLinearBrightness(_ linearBrightness: Double, for display: DisplayInfo) async {
        guard display.isBuiltin, let set = _DSSetLinearBrightness else {
            await setBrightness(linearBrightness * 100.0, for: display)
            return
        }
        let displayID = display.displayID
        let target = min(1.0, max(0.0, linearBrightness))
        cancelAnimation(for: displayID)
        manualAdjustLock.withLock { lastManualAdjustDate = Date() }
        PresetService.shared.noteManualChange()
        noteManualBrightnessChange(displayID: displayID, isBuiltin: true, value: display.brightness)

        let userBrightness: Double? = await withCheckedContinuation { continuation in
            queue.async {
                guard set(displayID, Float(target)) == 0, let get = _DSGetBrightness else {
                    continuation.resume(returning: nil)
                    return
                }
                var user: Float = 0
                continuation.resume(returning: get(displayID, &user) == 0 ? Double(user) * 100.0 : nil)
            }
        }
        if let userBrightness { display.brightness = userBrightness }
        BrightnessBoostService.shared.syncOverlay(for: display)
    }

    /// Smooth counterpart used by clicks, step buttons, and calibration changes.
    /// The animation itself is linear in nits; macOS converts every tick back to
    /// its nonlinear native slider curve.
    @MainActor
    func setBuiltinLinearBrightnessSmooth(
        _ linearBrightness: Double,
        for display: DisplayInfo,
        duration: TimeInterval = 0.20
    ) {
        guard display.isBuiltin, let set = _DSSetLinearBrightness else {
            setBrightnessSmooth(linearBrightness * 100.0, for: display, duration: duration)
            return
        }
        let displayID = display.displayID
        let target = min(1.0, max(0.0, linearBrightness))
        let from = self.linearBrightness(for: displayID) ?? target
        manualAdjustLock.withLock { lastManualAdjustDate = Date() }
        PresetService.shared.noteManualChange()
        noteManualBrightnessChange(displayID: displayID, isBuiltin: true, value: display.brightness)

        animator(for: displayID).animate(
            from: from,
            to: target,
            steps: max(8, Int(duration / 0.016)),
            duration: duration
        ) { [weak display] value, _ in
            guard let display, set(displayID, Float(value)) == 0, let get = _DSGetBrightness else { return }
            var user: Float = 0
            if get(displayID, &user) == 0 { display.brightness = Double(user) * 100.0 }
        }
    }

    // MARK: - Coalescing DDC Writer

    /// Latest pending brightness percent per display. Only one DDC write is in flight
    /// per display and intermediate targets are dropped (latest wins), so a fast
    /// slider drag can never build a queue of stale writes behind the slow I2C bus.
    private var pendingDDCPercent: [CGDirectDisplayID: Double] = [:]
    private var ddcPumpActive: Set<CGDirectDisplayID> = []
    private var ddcFailStreak: [CGDirectDisplayID: Int] = [:]
    /// Timestamp of the last DDC brightness write per display, used to pace writes.
    private var lastDDCWriteInstant: [CGDirectDisplayID: DispatchTime] = [:]
    private let ddcPumpLock = NSLock()

    /// Minimum spacing between consecutive DDC brightness writes to one display.
    /// The DDC/CI (MCCS) spec asks hosts to wait ~50ms after a "Set VCP Feature"
    /// before the next message; writing faster (a fast slider drag fires ~60/sec)
    /// floods the I2C bus and makes many panels visibly flicker. The coalescing
    /// pump still applies the latest value, this just caps the cadence at ~20/sec.
    private let minDDCWriteInterval: TimeInterval = 0.05

    /// DDC 0 on most monitors means "minimum backlight", which is still visibly bright.
    /// Below this percent we layer gamma dimming on top of the hardware write so the
    /// bottom of the slider actually reaches dark (gamma keeps its own 5% floor).
    private let gammaBlendThreshold = CombinedBrightnessMath.externalGammaBlendThreshold

    /// Externals currently in HDR mode. A DisplayHDR monitor manages its own
    /// luminance and silently discards DDC brightness writes (they still ack,
    /// so failure detection never fires), leaving 15-100% of the slider dead.
    /// While a display is in this set its whole 0-100 range dims in software
    /// instead. Maintained by BrightnessBoostService (HDR toggle, boost's
    /// auto-switch, and reconfiguration sync). Guarded by ddcAvailableLock.
    private var hdrDimmedDisplays: Set<CGDirectDisplayID> = []

    func setHDRSoftwareDimming(_ on: Bool, for displayID: CGDirectDisplayID) {
        ddcAvailableLock.withLock {
            if on { hdrDimmedDisplays.insert(displayID) } else { hdrDimmedDisplays.remove(displayID) }
        }
    }

    private func writeDDCBrightnessCoalesced(percent: Double, for displayID: CGDirectDisplayID) {
        // Single choke point for every DDC brightness write (direct sets and
        // glide ticks both land here), so this one check routes the full
        // range to gamma while the monitor is in HDR mode. DDC control
        // resumes automatically when HDR goes off: the first hardware write's
        // gamma reset below clears the leftover software dim.
        let hdrDimmed = ddcAvailableLock.withLock { hdrDimmedDisplays.contains(displayID) }
        if hdrDimmed {
            queue.async { [weak self] in
                self?.setSoftwareBrightness(percent, for: displayID)
            }
            return
        }
        ddcPumpLock.lock()
        pendingDDCPercent[displayID] = percent
        let alreadyPumping = ddcPumpActive.contains(displayID)
        if !alreadyPumping { ddcPumpActive.insert(displayID) }
        ddcPumpLock.unlock()
        if !alreadyPumping { pumpDDCWrite(for: displayID) }

        queue.async { [weak self] in
            guard let self else { return }
            if percent < self.gammaBlendThreshold {
                self.setSoftwareBrightness(percent / self.gammaBlendThreshold * 100.0, for: displayID)
            } else if let f = self.currentSoftwareBrightness(for: displayID), f < 1.0 {
                // Only clear a software dim once DDC has actually succeeded on
                // this display. While it is still unproven (nil), a display
                // whose writes all fail (Dell without a DDC channel) would
                // otherwise flash to full on every attempt, fighting the gamma
                // fallback that is actually doing the dimming.
                let proven = self.ddcAvailableLock.withLock { self.ddcAvailable[displayID] == true }
                if proven {
                    self.setSoftwareBrightness(100.0, for: displayID)
                }
            }
        }
    }

    private func pumpDDCWrite(for displayID: CGDirectDisplayID) {
        ddcPumpLock.lock()
        // Peek (don't consume yet): if we must wait to honour the pacing floor,
        // a newer drag value may arrive during the wait and should supersede this
        // one. Consuming only after the wait keeps "latest wins" intact.
        guard pendingDDCPercent[displayID] != nil else {
            ddcPumpActive.remove(displayID)
            ddcPumpLock.unlock()
            return
        }
        let last = lastDDCWriteInstant[displayID]
        ddcPumpLock.unlock()

        // Pace writes: if the previous write was under minDDCWriteInterval ago,
        // wait out the remainder before issuing the next one. Without this the
        // recursive pump fires writes back-to-back and floods the DDC/CI bus.
        if let last {
            let now = DispatchTime.now()
            let elapsed = now.uptimeNanoseconds >= last.uptimeNanoseconds
                ? Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000
                : minDDCWriteInterval
            let remaining = minDDCWriteInterval - elapsed
            if remaining > 0 {
                queue.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    self?.pumpDDCWrite(for: displayID)
                }
                return
            }
        }

        // Now consume the latest pending value (drops any intermediate drag steps).
        ddcPumpLock.lock()
        guard let percent = pendingDDCPercent.removeValue(forKey: displayID) else {
            ddcPumpActive.remove(displayID)
            ddcPumpLock.unlock()
            return
        }
        lastDDCWriteInstant[displayID] = .now()
        ddcPumpLock.unlock()

        // Denormalize percentage to display's native DDC range.
        // If max is unknown, default to 100 (safe for most monitors).
        let knownMax: UInt16 = ddcAvailableLock.withLock {
            ddcMaxBrightness[displayID] ?? 100
        }
        let ddcValue = UInt16((percent / 100.0) * Double(knownMax))

        DDCService.shared.writeAsync(
            displayID: displayID,
            command: DDCService.brightnessVCP,
            value: ddcValue
        ) { [weak self] success in
            guard let self else { return }
            if success {
                self.ddcAvailableLock.withLock { self.ddcAvailable[displayID] = true }
                self.ddcPumpLock.withLock { self.ddcFailStreak[displayID] = 0 }
            } else {
                let streak = self.ddcPumpLock.withLock { () -> Int in
                    let s = (self.ddcFailStreak[displayID] ?? 0) + 1
                    self.ddcFailStreak[displayID] = s
                    return s
                }
                // A single flaky I2C write must not flip the display into gamma mode
                // mid-drag (DDC + gamma dimming stack up and later "reset" visibly).
                // Only give up on DDC after 3 consecutive failures.
                if streak >= 3 {
                    self.ddcAvailableLock.withLock { self.ddcAvailable[displayID] = false }
                    DispatchQueue.main.async { [weak self] in
                        self?.setSoftwareBrightness(percent, for: displayID)
                    }
                }
            }
            self.pumpDDCWrite(for: displayID)
        }
    }

    // MARK: - Smooth Brightness Transitions

    /// Animate brightness from the display's current value to `targetBrightness` smoothly.
    ///
    /// - For DDC displays: sends 5 DDC commands spaced ~40ms apart (200ms total).
    ///   DDC I2C commands are inherently slow (~40–50ms each), so 5 steps at 40ms intervals
    ///   fills the 200ms window without flooding the bus.
    /// - For software (gamma) brightness: 8 gamma table updates over 200ms give a visibly
    ///   smooth fade without perceptible frame drops.
    /// - For built-in displays: 8 IOKit writes over 200ms mirror the software path.
    ///
    /// Cancels any previously running animation for the same display, so rapid key presses
    /// always feel responsive, the animation re-targets from wherever it currently is.
    @MainActor
    func setBrightnessSmooth(
        _ targetBrightness: Double,
        for display: DisplayInfo,
        isAutoAdjust: Bool = false,
        duration: TimeInterval = 0.20
    ) {
        let clamped = max(0.0, min(display.maxBrightness, targetBrightness))
        let displayID = display.displayID
        let fromBrightness = display.brightness

        if !isAutoAdjust {
            manualAdjustLock.withLock {
                lastManualAdjustDate = Date()
            }
            PresetService.shared.noteManualChange()
            noteManualBrightnessChange(displayID: displayID, isBuiltin: display.isBuiltin, value: clamped)
        }

        let anim = animator(for: displayID)

        // Step at ~125Hz (matches the 120Hz built-in panel) on every path:
        // display.brightness drives the UI slider, and NSSlider renders value
        // changes discretely (no interpolation), so the step rate IS the
        // knob's frame rate. Hardware paces itself: gamma and IOKit writes are
        // cheap; DDC goes through the coalescing writer, which drops steps the
        // ~45ms-per-write I2C bus can't take.
        let smoothSteps = max(8, Int(duration / 0.008))

        if display.isBuiltin {
            anim.animate(from: fromBrightness, to: clamped, steps: smoothSteps, duration: duration) { [weak self, weak display] value, _ in
                guard let self, let display else { return }
                display.brightness = value
                let floatVal = Float(min(value, 100.0) / 100.0)
                self.queue.async { self.setInternalBrightness(floatVal) }
                BrightnessBoostService.shared.syncOverlay(for: display)
            }
        } else {
            let currentStatus: Bool? = ddcAvailableLock.withLock { ddcAvailable[displayID] }

            if currentStatus == false {
                // Software (gamma) path. The transfer-table write is a
                // synchronous WindowServer call, so it goes to the background
                // queue like the built-in path's IOKit write; at 125 steps/s
                // it would otherwise stall the main thread mid-glide.
                anim.animate(from: fromBrightness, to: clamped,
                             steps: smoothSteps, duration: duration) { [weak self, weak display] value, _ in
                    guard let self, let display else { return }
                    display.brightness = value
                    // Above 100 the boost sync owns the transfer table (see setBrightness).
                    if value <= 100 {
                        self.queue.async { self.setSoftwareBrightness(value, for: displayID) }
                    }
                    BrightnessBoostService.shared.syncOverlay(for: display)
                }
            } else {
                // DDC path, routed through the coalescing writer so steps that
                // outpace the I2C bus are dropped instead of queued.
                anim.animate(from: fromBrightness, to: clamped,
                             steps: smoothSteps, duration: duration) { [weak self, weak display] value, _ in
                    guard let self, let display else { return }
                    display.brightness = value
                    // Above 100 the boost sync owns the transfer table (see setBrightness).
                    if value <= 100 {
                        self.writeDDCBrightnessCoalesced(percent: value, for: displayID)
                    }
                    BrightnessBoostService.shared.syncOverlay(for: display)
                }
            }
        }
    }

    // MARK: - Software Brightness (Gamma Table Fallback)

    /// Applies brightness via gamma table manipulation for displays where DDC is unavailable.
    /// Uses a linear ramp from 0 to `factor` so white level is dimmed while black stays black.
    /// brightness: 0–100 (percentage); never goes fully to 0 to avoid a completely black screen.
    /// Above 100 (external boost region, monitor in HDR mode) the same ramp scales past 1.0,
    /// pushing SDR content into the HDR wire range; the monitor tone-maps the result.
    ///
    /// If GammaService has an active adjustment for this display, it delegates to GammaService
    /// so the two do not overwrite each other's CGSetDisplayTransfer* call.
    func setSoftwareBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) {
        let factor = max(0.05, brightness / 100.0)
        softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] = factor }
        saveSoftwareBrightness(factor: factor, for: displayID)

        // If GammaService has an active adjustment, let it re-apply (it will incorporate the factor).
        if GammaService.shared.hasActiveAdjustment(for: displayID) {
            GammaService.shared.reapply(for: displayID)
            return
        }

        // No active gamma adjustment, write a plain dimmed ramp directly.
        let floatFactor = Float(factor)
        let tableSize: UInt32 = 256
        var red   = [CGGammaValue](repeating: 0, count: Int(tableSize))
        var green = [CGGammaValue](repeating: 0, count: Int(tableSize))
        var blue  = [CGGammaValue](repeating: 0, count: Int(tableSize))

        for i in 0..<Int(tableSize) {
            let v = CGGammaValue(Float(i) / Float(tableSize - 1) * floatFactor)
            red[i]   = v
            green[i] = v
            blue[i]  = v
        }

        _ = CGSetDisplayTransferByTable(displayID, tableSize, &red, &green, &blue)
    }

    /// External boost region: BrightnessBoostService drives the transfer table
    /// above 1.0 through here, on the same serial queue as the dim path, so
    /// slider motion above and below 100 is always one writer, one table.
    func setBoostFactor(_ factor: Double, for displayID: CGDirectDisplayID) {
        queue.async { [weak self] in
            self?.setSoftwareBrightness(factor * 100.0, for: displayID)
        }
    }

    /// Resets the gamma table for a display back to the identity curve.
    func resetSoftwareBrightness(for displayID: CGDirectDisplayID) {
        let size = 256
        let values = (0..<size).map { CGGammaValue($0) / CGGammaValue(size - 1) }
        var red = values
        var green = values
        var blue = values
        CGSetDisplayTransferByTable(displayID, UInt32(size), &red, &green, &blue)
    }

    /// Returns whether DDC is available for the given display.
    /// nil means not yet determined (first use).
    func isDDCAvailable(for displayID: CGDirectDisplayID) -> Bool? {
        ddcAvailableLock.withLock { ddcAvailable[displayID] }
    }

    /// Clears all per-display state for a disconnected display.
    /// Call this when a display is removed so stale state cannot pollute a reconnect.
    @MainActor
    func invalidateDDCState(for displayID: CGDirectDisplayID) {
        ddcAvailableLock.withLock {
            ddcAvailable.removeValue(forKey: displayID)
            ddcMaxBrightness.removeValue(forKey: displayID)
            // Display IDs are reused: without this, a disconnected HDR
            // display's software-dimming routing would stick to whatever
            // display inherits its ID next.
            hdrDimmedDisplays.remove(displayID)
        }
        // Same ID-reuse hazard for the rest: reapplySoftwareBrightnessIfNeeded
        // reads the in-memory factor first, so a display inheriting this ID
        // would silently get the departed display's dimming factor.
        animators[displayID]?.cancel()
        animators.removeValue(forKey: displayID)
        softwareBrightnessLock.withLock {
            _ = softwareBrightnessFactors.removeValue(forKey: displayID)
        }
        ddcPumpLock.withLock {
            pendingDDCPercent.removeValue(forKey: displayID)
            ddcFailStreak.removeValue(forKey: displayID)
            lastDDCWriteInstant.removeValue(forKey: displayID)
            // ddcPumpActive stays: the pump owns it and removes itself once it
            // sees no pending value.
        }
    }

    /// Re-applies the software brightness for a display after wake from sleep or hot-plug.
    /// Checks in-memory factor first; falls back to UserDefaults so restart is handled too.
    /// No-op if no saved factor < 1.0 exists.
    func reapplySoftwareBrightnessIfNeeded(for display: DisplayInfo) {
        let displayID = display.displayID
        let inMemory = softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] }
        let factor = inMemory ?? loadSoftwareBrightness(for: displayID)
        guard let f = factor, f < 1.0 else { return }
        // Populate in-memory cache if loaded from disk
        if inMemory == nil {
            softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] = f }
        }
        setSoftwareBrightness(f * 100.0, for: displayID)
    }

    // MARK: - Internal Display (IODisplayGetFloatParameter)

    private static nonisolated(unsafe) let ioDisplayBrightnessKey = "brightness" as CFString

    /// Returns the io_service_t for the built-in display using CGDisplayIOServicePort.
    /// Falls back to iterating IODisplayConnect services if CGDisplayIOServicePort returns null.
    /// Caller does NOT need to release, CGDisplayIOServicePort returns a non-retained port.
    private func builtinIOService() -> io_service_t? {
        // Find the built-in CGDirectDisplayID
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        guard let builtinID = (0..<Int(displayCount))
            .map({ displayIDs[$0] })
            .first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            return nil
        }

        // CGDisplayIOServicePort returns a non-retained service port (do not release)
        let servicePort = CGDisplayIOServicePort(builtinID)
        if servicePort != MACH_PORT_NULL && servicePort != 0 {
            return servicePort
        }

        return nil
    }

    /// Returns the CGDirectDisplayID of the built-in display, if any.
    private func builtinDisplayID() -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        return (0..<Int(displayCount)).map { displayIDs[$0] }.first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func getInternalBrightness() -> Double? {
        // Primary: DisplayServices (works on Apple Silicon, where IODisplayConnect is gone)
        if let get = _DSGetBrightness, let id = builtinDisplayID() {
            var v: Float = 0
            if get(id, &v) == 0 {
                return Double(v) * 100.0
            }
        }

        // Fallback: use CGDisplayIOServicePort to get the specific builtin display service
        if let servicePort = builtinIOService() {
            var value: Float = 0
            if IODisplayGetFloatParameter(
                servicePort, 0, Self.ioDisplayBrightnessKey, &value
            ) == KERN_SUCCESS {
                return Double(value) * 100.0
            }
        }

        // Fallback: iterate IODisplayConnect but only accept services that
        // correspond to a built-in display (matched via CGDisplayIOServicePort cross-check).
        // Build set of known external service ports to exclude them.
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        var externalPorts = Set<io_service_t>()
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if CGDisplayIsBuiltin(id) == 0 {
                let port = CGDisplayIOServicePort(id)
                if port != MACH_PORT_NULL && port != 0 {
                    externalPorts.insert(port)
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            // Skip services that are known external display ports
            guard !externalPorts.contains(service) else { continue }
            var value: Float = 0
            if IODisplayGetFloatParameter(
                service, 0, Self.ioDisplayBrightnessKey, &value
            ) == KERN_SUCCESS {
                return Double(value) * 100.0
            }
        }
        return nil
    }

    private func setInternalBrightness(_ value: Float) {
        // Primary: DisplayServices (works on Apple Silicon, where IODisplayConnect is gone)
        if let set = _DSSetBrightness, let id = builtinDisplayID() {
            if set(id, value) == 0 {
                return
            }
        }

        // Fallback: use CGDisplayIOServicePort to target only the builtin display service
        if let servicePort = builtinIOService() {
            if IODisplaySetFloatParameter(
                servicePort, 0, Self.ioDisplayBrightnessKey, value
            ) == KERN_SUCCESS {
                return
            }
        }

        // Fallback: iterate IODisplayConnect, skipping known external ports
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        var externalPorts = Set<io_service_t>()
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if CGDisplayIsBuiltin(id) == 0 {
                let port = CGDisplayIOServicePort(id)
                if port != MACH_PORT_NULL && port != 0 {
                    externalPorts.insert(port)
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            guard !externalPorts.contains(service) else { continue }
            if IODisplaySetFloatParameter(
                service, 0, Self.ioDisplayBrightnessKey, value
            ) == KERN_SUCCESS {
                return
            }
        }
    }
}
