import Foundation
import IOKit
import IOKit.graphics
import CoreGraphics
// For CGDisplayCreateUUIDFromDisplayID (ApplicationServices, not CoreGraphics).
import AppKit
import os.log

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

// DisplayServices private framework: built-in panel brightness on Apple
// Silicon, where IODisplayConnect no longer exists. Loaded via dlsym, same
// pattern as AutoBrightnessService.
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
private let _DSCanChangeBrightness: (@convention(c) (CGDirectDisplayID) -> Bool)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesCanChangeBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID) -> Bool).self)
}()

// DisplayServices brightness-change notifications: push updates so the UI
// tracks the built-in panel and Apple displays live instead of only
// refreshing on panel-open/wake/reconfigure. register(did, passthrough,
// callback) plus a 5-arg callback; brightness is not passed, it's read back
// via DisplayServicesGetBrightness.
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

/// C callback fired when a display's brightness changes from any source: reads the new
/// value back (see above) and pushes it onto the matching DisplayInfo on the main actor.
/// Must be a capture-free top-level function to be usable as a @convention(c) pointer.
private func _crispNativeBrightnessChanged(
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
        // Drive auto-brightness off this live change so externals follow the
        // built-in immediately instead of trailing its poll (issue #12).
        guard display.isBuiltin else { return }
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

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// The value a running fade is heading for, nil while idle. A key repeat
    /// must step from this, not the value mid-fade, or a press partway
    /// through computes the same stop again. See BrightnessKeyService.
    var pendingTarget: Double? { timer == nil ? nil : targetValue }

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

    /// Wraps BrightnessAnimator.pendingTarget (see its doc) for the given display.
    @MainActor
    func inFlightTarget(for displayID: CGDirectDisplayID) -> Double? {
        animators[displayID]?.pendingTarget
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

    /// UUID-keyed like GammaPersistenceKey (issue #32): a raw-ID key could
    /// hand this display's dimming factor to a different physical display.
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

    /// Moves any legacy displayID-keyed factor onto the stable UUID key, for
    /// every online display. Same rules as GammaService.migrateLegacyStateIfNeeded:
    /// idempotent, never overwrites an existing UUID entry, leaves a legacy
    /// key with no live display alone.
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

    func currentSoftwareBrightness(for displayID: CGDirectDisplayID) -> Double? {
        softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] }
    }

    // MARK: - DDC Availability Cache

    /// Tracks whether hardware DDC is available for each external display.
    /// nil  = not yet determined
    /// true = DDC write succeeded at least once
    /// false = DDC write has failed; use software (gamma) fallback
    private static let log = Logger(subsystem: "com.crisp.app", category: "brightness")

    private var ddcAvailable: [CGDirectDisplayID: Bool] = [:]
    private let ddcAvailableLock = NSLock()

    /// Per-display DDC max brightness value reported by the monitor.
    /// Used to denormalize 0–100% into the display's native DDC range.
    private var ddcMaxBrightness: [CGDirectDisplayID: UInt16] = [:]

    // MARK: - Public API

    /// Whether the built-in panel can be driven in linear luminance. Both
    /// private DisplayServices symbols must resolve; otherwise a linear value
    /// fed to the native percent API lands visibly wrong.
    static let supportsLinearBrightness = _DSSetLinearBrightness != nil && _DSGetLinearBrightness != nil

    /// Native panel brightness in a linear luminance domain. Multiplying this
    /// by DisplayInfo.nominalMaxNits yields the current estimated nits.
    func linearBrightness(for displayID: CGDirectDisplayID) -> Double? {
        guard let get = _DSGetLinearBrightness else { return nil }
        var value: Float = 0
        guard get(displayID, &value) == 0 else { return nil }
        return min(1.0, max(0.0, Double(value)))
    }

    /// `animated: true` glides the slider to the freshly-read value instead of
    /// snapping (used by the poll, so ambient auto-adjust reads as motion).
    /// Instant (default) on load/wake, where the slider should show the real
    /// value immediately.
    @MainActor
    func refreshBrightness(for display: DisplayInfo, animated: Bool = false) async {
        // While boosted above 100 the hardware reads back ~100; adopting that
        // would snap the slider out of the boost region.
        if display.brightness > 100.0 { return }
        let displayID = display.displayID

        if display.hasNativeBrightness {
            let brightness = await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    continuation.resume(returning: self?.nativeBrightness(for: displayID))
                }
            }
            if let b = brightness {
                // macOS already moved the backlight; only the displayed value
                // needs to catch up. Glide it (no hardware write) so the knob
                // doesn't jump; sub-0.5% moves are imperceptible, just set them.
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
            let readToken = ddcPumpLock.withLock {
                ddcOperationGeneration.currentToken(for: displayID)
            }
            // DDC already known unavailable: nothing to read back from gamma
            // tables, so leave the value as-is.
            let knownUnavailable: Bool = ddcAvailableLock.withLock {
                ddcAvailable[displayID] == false
            }
            if knownUnavailable {
                return
            }

            DDCService.shared.readAsync(
                displayID: displayID,
                command: DDCService.brightnessVCP
            ) { [weak self] result in
                guard let self else { return }
                if let result = result, result.max > 0 {
                    let brightness = Double(result.current) / Double(result.max) * 100.0
                    let firstRead: Bool? = self.ddcPumpLock.withLock {
                        guard self.ddcOperationGeneration.isCurrentTopology(
                            readToken, for: displayID
                        ) else { return nil }
                        return self.ddcAvailableLock.withLock {
                            let firstRead = self.ddcAvailable[displayID] != true
                            self.ddcAvailable[displayID] = true
                            self.ddcMaxBrightness[displayID] = result.max
                            return firstRead
                        }
                    }
                    guard let firstRead else { return }
                    if firstRead {
                        Self.log.notice("display \(displayID, privacy: .public): DDC brightness read ok \(result.current, privacy: .public)/\(result.max, privacy: .public), brightness over DDC")
                    }
                    Task { @MainActor in
                        // DDC reads quantize, so a value we just set can read
                        // back slightly off. Adopt the read only on first seed
                        // or a large enough change to be a real external move.
                        self.ddcPumpLock.withLock {
                            guard self.ddcOperationGeneration.isLatestRequest(
                                readToken, for: displayID
                            ) else { return }
                            if firstRead || abs(brightness - display.brightness) > 3.0 {
                                display.brightness = brightness
                            }
                        }
                    }
                }
                // A failed/ignored read does NOT mean DDC is unavailable: many
                // monitors accept writes but never answer reads. Leaving
                // availability undetermined lets the write path decide instead
                // of wrongly forcing the software fallback (see docs/ddc-notes.md).
            }
        }
    }

    /// The displays we currently observe for brightness changes.
    private var observedNativeIDs: Set<CGDirectDisplayID> = []

    /// Subscribes to brightness-change notifications for every display macOS
    /// dims itself, so the slider tracks live instead of only refreshing on
    /// panel-open/wake/reconfigure. Idempotent: registers new displays, drops
    /// departed ones, safe to call on every reconfiguration.
    @MainActor
    func startObservingNativeBrightness(for displays: [DisplayInfo]) {
        guard let register = _DSRegisterBrightnessChange,
              let unregister = _DSUnregisterBrightnessChange else { return }
        let wanted = Set(displays.filter(\.hasNativeBrightness).map(\.displayID))
        for id in observedNativeIDs.subtracting(wanted) { _ = unregister(id, id) }
        for id in wanted.subtracting(observedNativeIDs) { _ = register(id, id, _crispNativeBrightnessChanged) }
        observedNativeIDs = wanted
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

        if display.hasNativeBrightness {
            let value = Float(hardware / 100.0)
            display.brightness = clamped
            queue.async { [weak self] in
                self?.setNativeBrightness(value, for: displayID)
            }
        } else {
            display.brightness = clamped
            // Above 100 the transfer table belongs to the boost sync
            // (BrightnessBoostService.syncOverlay below); writing here too
            // would race it.
            if clamped <= 100 {
                let currentStatus: Bool? = ddcAvailableLock.withLock { ddcAvailable[displayID] }

                if currentStatus == false {
                    // DDC known unavailable, go straight to software fallback
                    applyLatestSoftwareBrightness(hardware, for: displayID)
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
    /// Callers check `supportsLinearBrightness` first; without the API this is a no-op.
    @MainActor
    func setBuiltinLinearBrightness(_ linearBrightness: Double, for display: DisplayInfo) async {
        guard display.isBuiltin, let set = _DSSetLinearBrightness else { return }
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
        guard display.isBuiltin, let set = _DSSetLinearBrightness else { return }
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
        ) { [weak self, weak display] value, _ in
            // The private DisplayServices calls are IPC: keep them off the main
            // thread like the single-shot path above, publish the read-back on main.
            self?.queue.async {
                guard set(displayID, Float(value)) == 0, let get = _DSGetBrightness else { return }
                var user: Float = 0
                guard get(displayID, &user) == 0 else { return }
                let brightness = Double(user) * 100.0
                DispatchQueue.main.async { display?.brightness = brightness }
            }
        }
    }

    // MARK: - Coalescing DDC Writer

    private struct PendingDDCTarget {
        let percent: Double
        let token: DDCOperationGeneration.Token
    }

    /// Latest pending brightness target per display. Only one DDC write is in flight
    /// per display and intermediate targets are dropped (latest wins), so a fast
    /// slider drag can never build a queue of stale writes behind the slow I2C bus.
    private var pendingDDCTarget: [CGDirectDisplayID: PendingDDCTarget] = [:]
    private var ddcPumpActive: Set<CGDirectDisplayID> = []
    /// Consecutive failed DDC brightness writes per display, so one dropped
    /// command cannot latch the display to software gamma (see pumpDDCWrite).
    private var ddcFailStreak: [CGDirectDisplayID: Int] = [:]
    private var ddcOperationGeneration = DDCOperationGeneration()
    /// Timestamp of the last DDC brightness write per display, used to pace writes.
    private var lastDDCWriteInstant: [CGDirectDisplayID: DispatchTime] = [:]
    private let ddcPumpLock = NSLock()

    /// Minimum spacing between DDC brightness writes to one display, per the
    /// DDC/CI spec (see docs/ddc-notes.md); caps cadence at ~20/sec so a fast
    /// slider drag can't flood the I2C bus.
    private let minDDCWriteInterval: TimeInterval = 0.05

    /// Below this percent, gamma dimming layers on top of the DDC write so
    /// the slider bottom reaches dark (see docs/brightness-notes.md).
    private let gammaBlendThreshold = CombinedBrightnessMath.externalGammaBlendThreshold

    /// Externals currently in HDR mode, whose whole 0-100 range dims in
    /// software instead of DDC (see docs/brightness-notes.md). Maintained by
    /// BrightnessBoostService. Guarded by ddcAvailableLock.
    private var hdrDimmedDisplays: Set<CGDirectDisplayID> = []

    private func applyLatestSoftwareBrightness(_ percent: Double, for displayID: CGDirectDisplayID) {
        let token = ddcPumpLock.withLock {
            ddcOperationGeneration.nextRequest(for: displayID)
        }
        queue.async { [weak self] in
            guard let self else { return }
            let isLatest = self.ddcPumpLock.withLock {
                self.ddcOperationGeneration.isLatestRequest(token, for: displayID)
            }
            guard isLatest else { return }
            self.setSoftwareBrightness(percent, for: displayID)
        }
    }

    func setHDRSoftwareDimming(_ on: Bool, for displayID: CGDirectDisplayID) {
        let changed = ddcAvailableLock.withLock {
            on ? hdrDimmedDisplays.insert(displayID).inserted : hdrDimmedDisplays.remove(displayID) != nil
        }
        if changed {
            Self.log.notice("display \(displayID, privacy: .public): HDR mode \(on ? "on, brightness routed to software gamma" : "off, brightness back on DDC", privacy: .public)")
        }
    }

    private func writeDDCBrightnessCoalesced(percent: Double, for displayID: CGDirectDisplayID) {
        // Single choke point for every DDC brightness write: routes the full
        // range to gamma while the monitor is in HDR mode. DDC resumes
        // automatically when HDR goes off.
        let hdrDimmed = ddcAvailableLock.withLock { hdrDimmedDisplays.contains(displayID) }
        if hdrDimmed {
            applyLatestSoftwareBrightness(percent, for: displayID)
            return
        }
        ddcPumpLock.lock()
        let token = ddcOperationGeneration.nextRequest(for: displayID)
        pendingDDCTarget[displayID] = PendingDDCTarget(percent: percent, token: token)
        let alreadyPumping = ddcPumpActive.contains(displayID)
        if !alreadyPumping { ddcPumpActive.insert(displayID) }
        ddcPumpLock.unlock()

        let ddcStatus = ddcAvailableLock.withLock { ddcAvailable[displayID] }
        queue.async { [weak self] in
            guard let self else { return }
            let isLatest = self.ddcPumpLock.withLock {
                self.ddcOperationGeneration.isLatestRequest(token, for: displayID)
            }
            guard isLatest else { return }
            if ddcStatus == nil {
                self.setSoftwareBrightness(percent, for: displayID)
            } else if ddcStatus == true {
                if percent < self.gammaBlendThreshold {
                    self.setSoftwareBrightness(
                        percent / self.gammaBlendThreshold * 100.0,
                        for: displayID
                    )
                } else if let factor = self.currentSoftwareBrightness(for: displayID), factor < 1.0 {
                    self.setSoftwareBrightness(100.0, for: displayID)
                }
            }
        }
        // Queue the visible preview before hardware work can complete and clear it.
        if !alreadyPumping { pumpDDCWrite(for: displayID, topology: token) }
    }

    private func pumpDDCWrite(
        for displayID: CGDirectDisplayID,
        topology: DDCOperationGeneration.Token
    ) {
        ddcPumpLock.lock()
        guard ddcOperationGeneration.isCurrentTopology(topology, for: displayID) else {
            ddcPumpLock.unlock()
            return
        }
        // Peek (don't consume yet): if we must wait to honour the pacing floor,
        // a newer drag value may arrive during the wait and should supersede this
        // one. Consuming only after the wait keeps "latest wins" intact.
        guard pendingDDCTarget[displayID] != nil else {
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
                    self?.pumpDDCWrite(for: displayID, topology: topology)
                }
                return
            }
        }

        // Now consume the latest pending value (drops any intermediate drag steps).
        ddcPumpLock.lock()
        guard ddcOperationGeneration.isCurrentTopology(topology, for: displayID) else {
            ddcPumpLock.unlock()
            return
        }
        guard let target = pendingDDCTarget.removeValue(forKey: displayID) else {
            ddcPumpActive.remove(displayID)
            ddcPumpLock.unlock()
            return
        }
        lastDDCWriteInstant[displayID] = .now()
        let percent = target.percent

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
                self.ddcWriteSucceeded(target, for: displayID)
            } else {
                self.ddcWriteFailed(target, for: displayID)
            }
        }
        // Keep topology invalidation behind the enqueue so a reconnect cannot put an
        // old request after the new display's first request on the per-display queue.
        ddcPumpLock.unlock()
    }

    /// The write landed: settle the software preview this target left behind
    /// (a stale gamma dim would stack on the hardware value) and hand the
    /// pump the next target.
    private func ddcWriteSucceeded(_ target: PendingDDCTarget, for displayID: CGDirectDisplayID) {
        let settled: (firstSuccess: Bool, hasNewerTarget: Bool)? = ddcPumpLock.withLock {
            guard ddcOperationGeneration.isCurrentTopology(target.token, for: displayID) else {
                return nil
            }
            let firstSuccess = ddcAvailableLock.withLock { () -> Bool in
                let was = ddcAvailable[displayID]
                ddcAvailable[displayID] = true
                return was != true
            }
            ddcFailStreak[displayID] = 0
            return (firstSuccess, pendingDDCTarget[displayID] != nil)
        }
        guard let settled else { return }
        if settled.firstSuccess {
            Self.log.notice("display \(displayID, privacy: .public): DDC brightness write acknowledged, brightness over DDC")
        }
        if settled.hasNewerTarget {
            pumpDDCWrite(for: displayID, topology: target.token)
            return
        }
        queue.async {
            // Decide under the lock, write outside it: setSoftwareBrightness is a
            // WindowServer gamma IPC plus a defaults write, and the refresh path
            // takes this lock on the main actor to adopt a read.
            let settle: Bool = self.ddcPumpLock.withLock {
                self.ddcOperationGeneration.isLatestRequest(target.token, for: displayID)
                    && self.pendingDDCTarget[displayID] == nil
            }
            if settle {
                let softwarePercent = target.percent < self.gammaBlendThreshold
                    ? target.percent / self.gammaBlendThreshold * 100.0
                    : 100.0
                self.setSoftwareBrightness(softwarePercent, for: displayID)
            }
            self.pumpDDCWrite(for: displayID, topology: target.token)
        }
    }

    /// The write failed. Latches to software only after three consecutive
    /// failures, not one: see docs/ddc-notes.md for why.
    private func ddcWriteFailed(_ target: PendingDDCTarget, for displayID: CGDirectDisplayID) {
        let outcome: (streak: Int, fallback: PendingDDCTarget?)? = ddcPumpLock.withLock {
            guard ddcOperationGeneration.isCurrentTopology(target.token, for: displayID) else {
                return nil
            }
            let streak = (ddcFailStreak[displayID] ?? 0) + 1
            ddcFailStreak[displayID] = streak
            guard streak >= 3 else { return (streak, nil) }
            ddcAvailableLock.withLock { ddcAvailable[displayID] = false }
            let latest = pendingDDCTarget.removeValue(forKey: displayID) ?? target
            ddcPumpActive.remove(displayID)
            return (streak, latest)
        }
        guard let outcome else { return }
        guard let fallback = outcome.fallback else {
            // Still inside the grace window: keep DDC, let the pump take the
            // next target (or stand down if there is none).
            pumpDDCWrite(for: displayID, topology: target.token)
            return
        }
        if outcome.streak == 3 {
            Self.log.notice("display \(displayID, privacy: .public): 3 consecutive DDC brightness writes failed, brightness now software gamma until reconnect")
        }
        queue.async {
            let isLatest = self.ddcPumpLock.withLock {
                self.ddcOperationGeneration.isLatestRequest(fallback.token, for: displayID)
            }
            guard isLatest else { return }
            self.setSoftwareBrightness(fallback.percent, for: displayID)
        }
    }

    // MARK: - Smooth Brightness Transitions

    /// Animates brightness to `targetBrightness`. DDC writes go through the
    /// coalescing pump (drops steps the I2C bus can't take); gamma and IOKit
    /// writes are cheap enough to take every step directly. Cancels any
    /// previous animation for the display and re-targets from wherever it is.
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

        // Step at ~125Hz: NSSlider renders value changes discretely, so the
        // step rate is the knob's visible frame rate. Hardware paces itself.
        let smoothSteps = max(8, Int(duration / 0.008))

        if display.hasNativeBrightness {
            anim.animate(from: fromBrightness, to: clamped, steps: smoothSteps, duration: duration) { [weak self, weak display] value, _ in
                guard let self, let display else { return }
                display.brightness = value
                let floatVal = Float(min(value, 100.0) / 100.0)
                self.queue.async { self.setNativeBrightness(floatVal, for: displayID) }
                BrightnessBoostService.shared.syncOverlay(for: display)
            }
        } else {
            let currentStatus: Bool? = ddcAvailableLock.withLock { ddcAvailable[displayID] }

            if currentStatus == false {
                // Software (gamma) path. The transfer-table write is a
                // synchronous WindowServer call, so it runs off the main
                // thread or it would stall mid-glide at 125 steps/s.
                anim.animate(from: fromBrightness, to: clamped,
                             steps: smoothSteps, duration: duration) { [weak self, weak display] value, _ in
                    guard let self, let display else { return }
                    display.brightness = value
                    // Above 100 the boost sync owns the transfer table (see setBrightness).
                    if value <= 100 {
                        self.applyLatestSoftwareBrightness(value, for: displayID)
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

    /// Applies brightness via gamma table for displays where DDC is unavailable:
    /// a linear ramp from 0 to `factor` (5% floor, never fully black), scaled
    /// past 1.0 above 100% for the external boost region. See
    /// docs/brightness-notes.md (gamma and software brightness). Delegates to
    /// GammaService when it has an active adjustment, so the two don't
    /// overwrite each other's transfer table.
    func setSoftwareBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) {
        let factor = max(0.05, brightness / 100.0)
        softwareBrightnessLock.withLock { softwareBrightnessFactors[displayID] = factor }
        saveSoftwareBrightness(factor: factor, for: displayID)

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
        applyLatestSoftwareBrightness(factor * 100.0, for: displayID)
    }

    func resetSoftwareBrightness(for displayID: CGDirectDisplayID) {
        let size = 256
        let values = (0..<size).map { CGGammaValue($0) / CGGammaValue(size - 1) }
        var red = values
        var green = values
        var blue = values
        CGSetDisplayTransferByTable(displayID, UInt32(size), &red, &green, &blue)
    }

    /// See ddcAvailable for what nil/true/false mean.
    func isDDCAvailable(for displayID: CGDirectDisplayID) -> Bool? {
        ddcAvailableLock.withLock { ddcAvailable[displayID] }
    }

    /// Returns a read-only snapshot of Crisp's current brightness route.
    @MainActor
    func brightnessBackend(for display: DisplayInfo) -> CrispControlBrightnessBackend {
        let displayID = display.displayID
        let state = ddcAvailableLock.withLock {
            (hdrDimmedDisplays.contains(displayID), ddcAvailable[displayID])
        }
        return CrispControlModel.brightnessBackend(
            // `builtin` is the route through macOS, which Apple externals share.
            isBuiltin: display.hasNativeBrightness,
            hdrSoftwareDimming: state.0,
            ddcAvailable: state.1
        )
    }

    /// Invalidates transport state without discarding saved software settings.
    /// Called for every online external ID on a topology change, since IDs
    /// can swap physical panels without leaving the online display list.
    @MainActor
    func invalidateDDCTopology(for displayIDs: Set<CGDirectDisplayID>) {
        for displayID in displayIDs {
            animators[displayID]?.cancel()
        }
        ddcPumpLock.withLock {
            for displayID in displayIDs {
                ddcOperationGeneration.invalidate(displayID: displayID)
                pendingDDCTarget.removeValue(forKey: displayID)
                ddcPumpActive.remove(displayID)
                ddcFailStreak.removeValue(forKey: displayID)
                lastDDCWriteInstant.removeValue(forKey: displayID)
            }
            ddcAvailableLock.withLock {
                for displayID in displayIDs {
                    ddcAvailable.removeValue(forKey: displayID)
                    ddcMaxBrightness.removeValue(forKey: displayID)
                }
            }
        }
    }

    /// Clears all per-display state for a disconnected display.
    /// Call this when a display is removed so stale state cannot pollute a reconnect.
    @MainActor
    func invalidateDDCState(for displayID: CGDirectDisplayID) {
        invalidateDDCTopology(for: [displayID])
        ddcAvailableLock.withLock {
            // Display IDs are reused: without this, HDR software-dimming
            // routing would stick to whatever display inherits the ID next.
            _ = hdrDimmedDisplays.remove(displayID)
        }
        // Same ID-reuse hazard: reapplySoftwareBrightnessIfNeeded reads the
        // in-memory factor first.
        animators.removeValue(forKey: displayID)
        softwareBrightnessLock.withLock {
            _ = softwareBrightnessFactors.removeValue(forKey: displayID)
        }
    }

    /// Re-applies the software brightness for a display after wake or hot-plug.
    /// Checks in-memory factor first, falls back to UserDefaults. No-op if no
    /// saved factor < 1.0 exists.
    func reapplySoftwareBrightnessIfNeeded(for display: DisplayInfo) {
        // Skip Apple externals (issue #169): a saved gamma dim factor from a
        // past fallback would stack on the real backlight with nothing to clear it.
        guard !display.hasNativeBrightness else { return }
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

    /// The built-in's io_service_t via CGDisplayIOServicePort. Caller does NOT
    /// need to release; the port is non-retained.
    private func builtinIOService() -> io_service_t? {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        guard let builtinID = (0..<Int(displayCount))
            .map({ displayIDs[$0] })
            .first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            return nil
        }

        let servicePort = CGDisplayIOServicePort(builtinID)
        if servicePort != MACH_PORT_NULL && servicePort != 0 {
            return servicePort
        }

        return nil
    }

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

        // Fallback: iterate IODisplayConnect, excluding known external ports.
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

// MARK: - Apple displays (#169)

extension BrightnessService {
    /// Apple's EDID vendor ID ("APP"), which the built-in panel reports too.
    private static let appleVendorID: UInt32 = 0x0610

    /// Whether macOS sets this display's backlight itself: the built-in, and
    /// Apple externals like Studio Display and Pro Display XDR, whose
    /// brightness System Settings changed but Crisp's DDC route did not
    /// (#169). The vendor check keeps every other monitor on DDC.
    static func hasNativeBrightness(_ displayID: CGDirectDisplayID) -> Bool {
        if CGDisplayIsBuiltin(displayID) != 0 { return true }
        guard CGDisplayVendorNumber(displayID) == appleVendorID,
              _DSCanChangeBrightness?(displayID) == true else { return false }
        log.notice("display \(displayID, privacy: .public): Apple display, brightness over DisplayServices")
        return true
    }

    /// The built-in keeps its own path (DisplayServices, then the IOKit fallbacks, which
    /// find the built-in on their own); an Apple external goes to DisplayServices only.
    fileprivate func nativeBrightness(for displayID: CGDirectDisplayID) -> Double? {
        if CGDisplayIsBuiltin(displayID) != 0 { return getInternalBrightness() }
        var value: Float = 0
        guard _DSGetBrightness?(displayID, &value) == 0 else { return nil }
        return Double(value) * 100.0
    }

    // ponytail: one DisplayServices write per call, as the built-in always had; if a
    // Studio Display lags behind a slider drag, coalesce like the DDC pump does.
    fileprivate func setNativeBrightness(_ value: Float, for displayID: CGDirectDisplayID) {
        if CGDisplayIsBuiltin(displayID) != 0 {
            setInternalBrightness(value)
        } else {
            _ = _DSSetBrightness?(displayID, value)
        }
    }
}
