import Foundation
import IOKit
import IOKit.graphics
import CoreGraphics

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

// DisplayServices private framework — built-in panel brightness on Apple Silicon,
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

        // If from ≈ to, no animation needed — just apply final value.
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

    /// Set when the user manually adjusts brightness; auto-brightness skips updates for 30 s.
    private(set) var lastManualAdjustDate: Date? = nil
    /// Manual changes to external displays only. Auto-brightness pauses on this
    /// one: a manual builtin change is the very signal it syncs from.
    private(set) var lastExternalManualAdjustDate: Date? = nil
    private let manualAdjustLock = NSLock()

    // MARK: - Software Brightness Factors

    /// Stores the current software brightness factor per display (0.01–1.0).
    private var softwareBrightnessFactors: [CGDirectDisplayID: Double] = [:]
    private let softwareBrightnessLock = NSLock()

    private func softBrightnessKey(for displayID: CGDirectDisplayID) -> String {
        "fd.softBrightness_\(displayID)"
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

    @MainActor
    func refreshBrightness(for display: DisplayInfo) async {
        let isBuiltin = display.isBuiltin
        let displayID = display.displayID

        if isBuiltin {
            let brightness = await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    continuation.resume(returning: self?.getInternalBrightness())
                }
            }
            if let b = brightness {
                display.brightness = b
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
                    self.ddcAvailable[displayID] = true
                    self.ddcMaxBrightness[displayID] = result.max
                    self.ddcAvailableLock.unlock()
                    Task { @MainActor in display.brightness = brightness }
                } else {
                    // DDC read returned nil; mark unavailable
                    self.ddcAvailableLock.lock()
                    if self.ddcAvailable[displayID] == nil {
                        self.ddcAvailable[displayID] = false
                    }
                    self.ddcAvailableLock.unlock()
                }
            }
        }
    }

    @MainActor
    func setBrightness(_ brightness: Double, for display: DisplayInfo, isAutoAdjust: Bool = false) async {
        let clamped = max(0.0, min(100.0, brightness))
        let isBuiltin = display.isBuiltin
        let displayID = display.displayID

        // Record manual adjust time so auto-brightness can honour the cooldown period.
        if !isAutoAdjust {
            manualAdjustLock.withLock {
                lastManualAdjustDate = Date()
                if !isBuiltin { lastExternalManualAdjustDate = Date() }
            }
            PresetService.shared.noteManualChange()
        }

        if isBuiltin {
            let value = Float(clamped / 100.0)
            display.brightness = clamped
            queue.async { [weak self] in
                self?.setInternalBrightness(value)
            }
        } else {
            // Check current DDC availability status
            let currentStatus: Bool? = ddcAvailableLock.withLock { ddcAvailable[displayID] }

            if currentStatus == false {
                // DDC known unavailable — go straight to software fallback
                queue.async { [weak self] in
                    self?.setSoftwareBrightness(clamped, for: displayID)
                }
                return
            }

            writeDDCBrightnessCoalesced(percent: clamped, for: displayID)
        }
    }

    // MARK: - Coalescing DDC Writer

    /// Latest pending brightness percent per display. Only one DDC write is in flight
    /// per display and intermediate targets are dropped (latest wins), so a fast
    /// slider drag can never build a queue of stale writes behind the slow I2C bus.
    private var pendingDDCPercent: [CGDirectDisplayID: Double] = [:]
    private var ddcPumpActive: Set<CGDirectDisplayID> = []
    private var ddcFailStreak: [CGDirectDisplayID: Int] = [:]
    private let ddcPumpLock = NSLock()

    /// DDC 0 on most monitors means "minimum backlight", which is still visibly bright.
    /// Below this percent we layer gamma dimming on top of the hardware write so the
    /// bottom of the slider actually reaches dark (gamma keeps its own 5% floor).
    private let gammaBlendThreshold = 15.0

    private func writeDDCBrightnessCoalesced(percent: Double, for displayID: CGDirectDisplayID) {
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
                self.setSoftwareBrightness(100.0, for: displayID)
            }
        }
    }

    private func pumpDDCWrite(for displayID: CGDirectDisplayID) {
        ddcPumpLock.lock()
        guard let percent = pendingDDCPercent.removeValue(forKey: displayID) else {
            ddcPumpActive.remove(displayID)
            ddcPumpLock.unlock()
            return
        }
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
                    #if DEBUG
                    print("[BrightnessService] DDC unavailable for display \(displayID), using software fallback")
                    #endif
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
    /// always feel responsive — the animation re-targets from wherever it currently is.
    @MainActor
    func setBrightnessSmooth(
        _ targetBrightness: Double,
        for display: DisplayInfo,
        isAutoAdjust: Bool = false,
        duration: TimeInterval = 0.20
    ) {
        let clamped = max(0.0, min(100.0, targetBrightness))
        let displayID = display.displayID
        let fromBrightness = display.brightness

        if !isAutoAdjust {
            manualAdjustLock.withLock {
                lastManualAdjustDate = Date()
                if !display.isBuiltin { lastExternalManualAdjustDate = Date() }
            }
            PresetService.shared.noteManualChange()
        }

        let anim = animator(for: displayID)

        // Step at ~60Hz on every path: display.brightness drives the UI slider,
        // and NSSlider renders value changes discretely (no interpolation), so
        // the step rate IS the knob's frame rate. Hardware paces itself: gamma
        // and IOKit writes are cheap; DDC goes through the coalescing writer,
        // which drops steps the ~45ms-per-write I2C bus can't take.
        let smoothSteps = max(8, Int(duration / 0.016))

        if display.isBuiltin {
            anim.animate(from: fromBrightness, to: clamped, steps: smoothSteps, duration: duration) { [weak self, weak display] value, _ in
                guard let self, let display else { return }
                display.brightness = value
                let floatVal = Float(value / 100.0)
                self.queue.async { self.setInternalBrightness(floatVal) }
            }
        } else {
            let currentStatus: Bool? = ddcAvailableLock.withLock { ddcAvailable[displayID] }

            if currentStatus == false {
                // Software (gamma) path
                anim.animate(from: fromBrightness, to: clamped, steps: smoothSteps, duration: duration) { [weak display] value, _ in
                    display?.brightness = value
                    BrightnessService.shared.setSoftwareBrightness(value, for: displayID)
                }
            } else {
                // DDC path, routed through the coalescing writer so steps that
                // outpace the I2C bus are dropped instead of queued.
                anim.animate(from: fromBrightness, to: clamped, steps: smoothSteps, duration: duration) { [weak self, weak display] value, _ in
                    guard let self else { return }
                    display?.brightness = value
                    self.writeDDCBrightnessCoalesced(percent: value, for: displayID)
                }
            }
        }
    }

    // MARK: - Software Brightness (Gamma Table Fallback)

    /// Applies brightness via gamma table manipulation for displays where DDC is unavailable.
    /// Uses a linear ramp from 0 to `factor` so white level is dimmed while black stays black.
    /// brightness: 0–100 (percentage); never goes fully to 0 to avoid a completely black screen.
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

        // No active gamma adjustment — write a plain dimmed ramp directly.
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

        let result = CGSetDisplayTransferByTable(displayID, tableSize, &red, &green, &blue)
        #if DEBUG
        if result != CGError.success {
            print("[BrightnessService] CGSetDisplayTransferByTable failed: \(result)")
        } else {
            print("[BrightnessService] software brightness set to \(Int(brightness))% for display \(displayID)")
        }
        #endif
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

    /// Clears DDC availability and max brightness cache for a disconnected display.
    /// Call this when a display is removed so stale state cannot pollute a reconnect.
    func invalidateDDCState(for displayID: CGDirectDisplayID) {
        ddcAvailableLock.withLock {
            ddcAvailable.removeValue(forKey: displayID)
            ddcMaxBrightness.removeValue(forKey: displayID)
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
    /// Caller does NOT need to release — CGDisplayIOServicePort returns a non-retained port.
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
                #if DEBUG
                print("[BrightnessService] internal brightness set to \(value)")
                #endif
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
            #if DEBUG
            print("[BrightnessService] setInternalBrightness: no builtin service responded")
            #endif
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
                #if DEBUG
                print("[BrightnessService] internal brightness set to \(value)")
                #endif
                return
            }
        }
        #if DEBUG
        print("[BrightnessService] setInternalBrightness: no builtin service responded")
        #endif
    }
}
