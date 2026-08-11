import AppKit
import CoreGraphics
@preconcurrency import ColorSync

/// Per-display software image adjustment parameters.
/// All slider values are in the range -100...+100 with 0 = neutral,
/// except quantizationLevels (2...256, 256 = no quantization).
struct GammaAdjustment {
    var contrast: Double = 0.0          // -100 to +100, 0 = neutral
    var gammaVal: Double = 0.0          // -100 to +100, 0 = neutral (gamma exponent 1.0)
    var gain: Double = 0.0              // -100 to +100, 0 = neutral (multiplier 1.0)
    var colorTemperature: Double = 0.0  // -100 to +100, 0 = neutral (6500 K)
    var rGamma: Double = 0.0            // per-channel gamma offset
    var gGamma: Double = 0.0
    var bGamma: Double = 0.0
    var rGain: Double = 0.0             // per-channel gain offset
    var gGain: Double = 0.0
    var bGain: Double = 0.0
    var quantizationLevels: Int = 256   // 256 = no quantization
    var isInverted: Bool = false
    var isPaused: Bool = false
}

/// Applies software gamma / image adjustments to a display using
/// CoreGraphics CGSetDisplayTransferByFormula / CGSetDisplayTransferByTable.
final class GammaService: @unchecked Sendable {
    static let shared = GammaService()
    private var terminateObserver: NSObjectProtocol?
    private var profileObservers: [NSObjectProtocol] = []
    private let adjustmentsLock = NSLock()

    private init() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            var displayCount: UInt32 = 0
            CGGetOnlineDisplayList(32, nil, &displayCount)
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
            CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
            for displayID in displays {
                let size = 256
                var r = (0..<size).map { CGGammaValue($0) / CGGammaValue(size - 1) }
                var g = r; var b = r
                CGSetDisplayTransferByTable(displayID, UInt32(size), &r, &g, &b)
            }
        }
        observeProfileChanges()
    }

    deinit {
        if let obs = terminateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        for obs in profileObservers {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
    }

    /// Display profile changes (including the post-wake ICC restore, the prime
    /// suspect for the table clobber in issue #25) announce themselves through
    /// ColorSync's distributed notifications. Reapplying in direct response is
    /// the event-driven complement to the timed wake passes; if sleep-testing
    /// shows this catches every clobber, the timed passes can be deleted.
    /// No feedback loop: reapply only writes transfer tables, never profiles,
    /// and resetSingleDisplay drops its display from activeAdjustments before
    /// its ColorSync write, so the resulting notification no-ops for it.
    private func observeProfileChanges() {
        let names = [
            kColorSyncDeviceProfilesNotification,
            kColorSyncDisplayDeviceProfilesNotification
        ].compactMap { $0?.takeUnretainedValue() as String? }
        for name in names {
            profileObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                self?.reapplyAllActive()
            })
        }
    }

    /// Re-applies every active (non-paused) adjustment. Idempotent.
    private func reapplyAllActive() {
        let ids = adjustmentsLock.withLock { Array(activeAdjustments.keys) }
        for id in ids { reapply(for: id) }
    }

    // MARK: - Active Adjustment Tracking

    /// Stores the most recently applied non-paused adjustment per display.
    private var activeAdjustments: [CGDirectDisplayID: GammaAdjustment] = [:]

    /// Returns true if there is a currently active (non-paused) gamma adjustment for this display.
    func hasActiveAdjustment(for displayID: CGDirectDisplayID) -> Bool {
        adjustmentsLock.withLock {
            guard let adj = activeAdjustments[displayID] else { return false }
            return !adj.isPaused
        }
    }

    /// Re-applies the stored adjustment (incorporating the current software brightness factor).
    func reapply(for displayID: CGDirectDisplayID) {
        let adj = adjustmentsLock.withLock { activeAdjustments[displayID] }
        guard let adj, !adj.isPaused else { return }
        applyInternal(adj, for: displayID)
    }

    // MARK: - Public API

    /// Apply a complete GammaAdjustment snapshot to the given display.
    func apply(_ adj: GammaAdjustment, for displayID: CGDirectDisplayID) {
        guard !adj.isPaused else { return }
        adjustmentsLock.withLock { activeAdjustments[displayID] = adj }
        applyInternal(adj, for: displayID)
    }

    private func applyInternal(_ adj: GammaAdjustment, for displayID: CGDirectDisplayID) {
        if adj.quantizationLevels < 256 {
            applyQuantizedTable(adj, for: displayID)
        } else {
            applyFormula(adj, for: displayID)
        }
    }

    /// Apply identity transfer (gamma 1.0) to a single display without
    /// discarding stored parameters. Used by "pause" mode.
    func applyIdentity(for displayID: CGDirectDisplayID) {
        // Mark the adjustment as paused so hasActiveAdjustment returns false.
        adjustmentsLock.withLock {
            if var adj = activeAdjustments[displayID] {
                adj.isPaused = true
                activeAdjustments[displayID] = adj
            }
        }
        CGSetDisplayTransferByFormula(displayID,
            0.0, 1.0, 1.0,
            0.0, 1.0, 1.0,
            0.0, 1.0, 1.0)
    }

    /// Restore all online displays to identity gamma (per-display, avoids global reset).
    func restoreColorSync() {
        adjustmentsLock.withLock { activeAdjustments.removeAll() }
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        for displayID in displays {
            resetSingleDisplay(displayID)
        }
    }

    /// Resets gamma to identity for a single display without affecting other displays.
    /// Also removes any custom ColorSync profile override so the factory ICC profile
    /// is restored, preventing a "flat" / uncalibrated appearance after reset.
    /// Prefer this over `restoreColorSync()` whenever only one display needs resetting.
    func resetSingleDisplay(_ displayID: CGDirectDisplayID) {
        _ = adjustmentsLock.withLock { activeAdjustments.removeValue(forKey: displayID) }
        let size = 256
        var r = (0..<size).map { CGGammaValue($0) / CGGammaValue(size - 1) }
        var g = r; var b = r
        CGSetDisplayTransferByTable(displayID, UInt32(size), &r, &g, &b)

        // Remove any custom ColorSync profile override so the factory ICC profile is
        // re-activated (equivalent to a per-display ColorSync restore).
        if let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
           let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
           let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue() {
            let uuid = rawUUID.takeRetainedValue()
            // Passing NSNull() for the profile key removes the custom override.
            let removeInfo: NSDictionary = [profileIDKey: NSNull()]
            ColorSyncDeviceSetCustomProfiles(deviceClass, uuid, removeInfo as CFDictionary)
        }
    }

    // MARK: - Persistence (displayUUID keyed, survives displayID reassignment; issue #32)

    /// Persist an adjustment under the display's stable UUID, not its `CGDirectDisplayID`:
    /// macOS can reassign the id across reboots/reconnects, which used to apply a saved
    /// color temperature to the wrong physical display on a dual-external setup.
    @MainActor
    func saveState(_ adj: GammaAdjustment, for display: DisplayInfo) {
        let dict: [String: Any] = [
            "contrast": adj.contrast,
            "gammaVal": adj.gammaVal,
            "gain": adj.gain,
            "colorTemperature": adj.colorTemperature,
            "rGamma": adj.rGamma, "gGamma": adj.gGamma, "bGamma": adj.bGamma,
            "rGain": adj.rGain, "gGain": adj.gGain, "bGain": adj.bGain,
            "quantizationLevels": adj.quantizationLevels,
            "isInverted": adj.isInverted,
            "isPaused": adj.isPaused
        ]
        UserDefaults.standard.set(dict, forKey: GammaPersistenceKey.uuidKey(for: display.displayUUID))
    }

    @MainActor
    func loadSavedState(for display: DisplayInfo) -> GammaAdjustment? {
        guard let dict = UserDefaults.standard.dictionary(forKey: GammaPersistenceKey.uuidKey(for: display.displayUUID)) else { return nil }
        var adj = GammaAdjustment()
        adj.contrast           = dict["contrast"]           as? Double ?? 0
        adj.gammaVal           = dict["gammaVal"]           as? Double ?? 0
        adj.gain               = dict["gain"]               as? Double ?? 0
        adj.colorTemperature   = dict["colorTemperature"]   as? Double ?? 0
        adj.rGamma             = dict["rGamma"]             as? Double ?? 0
        adj.gGamma             = dict["gGamma"]             as? Double ?? 0
        adj.bGamma             = dict["bGamma"]             as? Double ?? 0
        adj.rGain              = dict["rGain"]              as? Double ?? 0
        adj.gGain              = dict["gGain"]              as? Double ?? 0
        adj.bGain              = dict["bGain"]              as? Double ?? 0
        adj.quantizationLevels = dict["quantizationLevels"] as? Int    ?? 256
        adj.isInverted         = dict["isInverted"]         as? Bool   ?? false
        adj.isPaused           = dict["isPaused"]           as? Bool   ?? false
        return adj
    }

    @MainActor
    func clearSavedState(for display: DisplayInfo) {
        UserDefaults.standard.removeObject(forKey: GammaPersistenceKey.uuidKey(for: display.displayUUID))
    }

    /// Moves any legacy, `CGDirectDisplayID`-keyed saved adjustment onto the stable
    /// UUID key (issue #32), for every display currently online. Call whenever the
    /// display list is (re)built, e.g. from `DisplayManager.refreshDisplays()`, before
    /// anything reapplies a saved adjustment. Safe to call repeatedly: a no-op once a
    /// display has no legacy entry left, and never overwrites an adjustment already
    /// saved under the UUID key.
    ///
    /// Deliberately does not touch a legacy key whose displayID has no live display
    /// right now: that id may simply belong to a disconnected monitor, and guessing
    /// would risk applying a stale adjustment to the wrong physical display, the exact
    /// bug this migration fixes.
    @MainActor
    func migrateLegacyStateIfNeeded(for displays: [DisplayInfo]) {
        let defaults = UserDefaults.standard
        let live = displays.map { (id: $0.displayID, uuid: $0.displayUUID) }
        let legacyIDsWithState = Set(live.map(\.id).filter {
            defaults.dictionary(forKey: GammaPersistenceKey.legacyKey(for: $0)) != nil
        })
        guard !legacyIDsWithState.isEmpty else { return }
        for target in GammaPersistenceKey.migrationTargets(liveDisplays: live, legacyDisplayIDsWithSavedState: legacyIDsWithState) {
            guard let legacyDict = defaults.dictionary(forKey: target.legacyKey) else { continue }
            if defaults.dictionary(forKey: target.uuidKey) == nil {
                defaults.set(legacyDict, forKey: target.uuidKey)
            }
            defaults.removeObject(forKey: target.legacyKey)
        }
    }

    /// Re-applies the persisted gamma adjustment for a display (e.g. after wake from sleep
    /// or display reconnect). No-op if no saved state exists or the adjustment is paused.
    @MainActor
    func reapplyIfNeeded(for display: DisplayInfo) {
        guard let adj = loadSavedState(for: display), !adj.isPaused else { return }
        let displayID = display.displayID
        adjustmentsLock.withLock { activeAdjustments[displayID] = adj }
        applyInternal(adj, for: displayID)
    }

    // MARK: - Formula mode

    private struct ChannelParams {
        var rLo, rHi, rGam: Double
        var gLo, gHi, gGam: Double
        var bLo, bHi, bGam: Double
    }

    private func applyFormula(_ adj: GammaAdjustment, for displayID: CGDirectDisplayID) {
        var p = channelParams(for: adj)
        // Incorporate software brightness factor so BrightnessService and GammaService
        // do not overwrite each other's transfer function.
        let brightnessFactor = max(0.05, BrightnessService.shared.currentSoftwareBrightness(for: displayID) ?? 1.0)
        p.rHi *= brightnessFactor
        p.gHi *= brightnessFactor
        p.bHi *= brightnessFactor
        // Boost region (factor > 1, external in HDR mode): entries may rise to
        // the boosted top; in the normal range the 1.0 ceiling is unchanged.
        let cap = max(1.0, brightnessFactor)

        // Build the table by hand instead of CGSetDisplayTransferByFormula: the formula API
        // forces min/max into [0,1] with min<=max, which silently drops inversion (rLo>rHi),
        // positive gain (rHi>1), and positive contrast. Sampling the same curve into
        // CGSetDisplayTransferByTable and clamping per entry honors all three.
        let capacity = 256
        var redTable   = [CGGammaValue](repeating: 0, count: capacity)
        var greenTable = [CGGammaValue](repeating: 0, count: capacity)
        var blueTable  = [CGGammaValue](repeating: 0, count: capacity)
        for i in 0..<capacity {
            let input = Double(i) / Double(capacity - 1)
            func tableValue(lo: Double, hi: Double, gam: Double) -> CGGammaValue {
                CGGammaValue(max(0.0, min(cap, lo + (hi - lo) * pow(input, gam))))
            }
            redTable[i]   = tableValue(lo: p.rLo, hi: p.rHi, gam: p.rGam)
            greenTable[i] = tableValue(lo: p.gLo, hi: p.gHi, gam: p.gGam)
            blueTable[i]  = tableValue(lo: p.bLo, hi: p.bHi, gam: p.bGam)
        }
        CGSetDisplayTransferByTable(displayID, UInt32(capacity),
                                    &redTable, &greenTable, &blueTable)
    }

    private func channelParams(for adj: GammaAdjustment) -> ChannelParams {
        // ── Gamma exponent ──────────────────────────────────────────────
        // slider=0 → exp=1.0; +100 → 0.5 (brighter curve); -100 → 2.0 (darker)
        let globalGammaExp = pow(2.0, -adj.gammaVal / 100.0)
        let rGammaExp = globalGammaExp * pow(2.0, -adj.rGamma / 100.0)
        let gGammaExp = globalGammaExp * pow(2.0, -adj.gGamma / 100.0)
        let bGammaExp = globalGammaExp * pow(2.0, -adj.bGamma / 100.0)

        // ── Gain (output ceiling / brightness scale) ────────────────────
        // slider=0 → 1.0; +100 → 2.0; -100 → 0.0
        let globalGain = max(0.0, 1.0 + adj.gain / 100.0)
        let rGain = max(0.0, globalGain * (1.0 + adj.rGain / 100.0))
        let gGain = max(0.0, globalGain * (1.0 + adj.gGain / 100.0))
        let bGain = max(0.0, globalGain * (1.0 + adj.bGain / 100.0))

        // ── Color temperature ───────────────────────────────────────────
        let (tempR, tempG, tempB) = colorTempFactors(adj.colorTemperature)

        // Per-channel max after gain × color-temp
        let rHiBase = rGain * tempR
        let gHiBase = gGain * tempG
        let bHiBase = bGain * tempB

        // ── Contrast (symmetric push/pull of min and max) ───────────────
        // ±100% → ±0.4 shift, widening/narrowing the output range
        let contrastShift = adj.contrast / 250.0

        var rLo = 0.0 - contrastShift
        var gLo = 0.0 - contrastShift
        var bLo = 0.0 - contrastShift
        var rHi = rHiBase + contrastShift
        var gHi = gHiBase + contrastShift
        var bHi = bHiBase + contrastShift

        // ── Inversion (swap min ↔ max per channel) ─────────────────────
        if adj.isInverted {
            swap(&rLo, &rHi)
            swap(&gLo, &gHi)
            swap(&bLo, &bHi)
        }

        // No [0,1] clamp here: the apply paths sample these endpoints into a transfer table
        // and clamp per entry, so out-of-range endpoints are preserved and drive real effects,
        // inversion (rLo>rHi), positive gain (rHi>1), and positive contrast (rHi>1, rLo<0).
        // Clamping here would pin rHi to 1.0 and silently no-op gain and contrast above 0.

        return ChannelParams(
            rLo: rLo, rHi: rHi, rGam: rGammaExp,
            gLo: gLo, gHi: gHi, gGam: gGammaExp,
            bLo: bLo, bHi: bHi, bGam: bGammaExp)
    }

    // MARK: - Color temperature (Tanner Helland algorithm)

    /// Returns per-channel gain multipliers normalised so that 6500 K → (1, 1, 1).
    private func colorTempFactors(_ sliderValue: Double) -> (r: Double, g: Double, b: Double) {
        guard sliderValue != 0.0 else { return (1.0, 1.0, 1.0) }
        // positive slider = warmer (lower K); negative = cooler (higher K)
        let kelvin: Double
        if sliderValue > 0 {
            kelvin = 6500.0 - sliderValue / 100.0 * 4500.0  // 6500 K → 2000 K
        } else {
            kelvin = 6500.0 - sliderValue / 100.0 * 5500.0  // 6500 K → 12000 K
        }
        let (r, g, b) = kelvinToRGB(kelvin)
        let (rN, gN, bN) = kelvinToRGB(6500.0)
        return (
            rN > 0 ? r / rN : r,
            gN > 0 ? g / gN : g,
            bN > 0 ? b / bN : b
        )
    }

    private func kelvinToRGB(_ kelvin: Double) -> (Double, Double, Double) {
        let temp = max(1000.0, min(40000.0, kelvin)) / 100.0

        let r: Double
        if temp <= 66 {
            r = 1.0
        } else {
            r = max(0, min(1, 1.292936186 * pow(temp - 60, -0.1332047592)))
        }

        let g: Double
        if temp <= 66 {
            g = max(0, min(1, 0.390081579 * log(temp) - 0.631841444))
        } else {
            g = max(0, min(1, 1.129890861 * pow(temp - 60, -0.0755148492)))
        }

        let b: Double
        if temp >= 66 {
            b = 1.0
        } else if temp <= 19 {
            b = 0.0
        } else {
            b = max(0, min(1, 0.543206789 * log(temp - 10) - 1.196254089))
        }

        return (r, g, b)
    }

    // MARK: - Quantization (table mode)

    private func applyQuantizedTable(_ adj: GammaAdjustment, for displayID: CGDirectDisplayID) {
        let levels = max(2, min(255, adj.quantizationLevels))
        let capacity = 256

        var redTable   = [CGGammaValue](repeating: 0, count: capacity)
        var greenTable = [CGGammaValue](repeating: 0, count: capacity)
        var blueTable  = [CGGammaValue](repeating: 0, count: capacity)

        var p = channelParams(for: adj)
        // Incorporate software brightness factor, matching applyFormula behaviour.
        let brightnessFactor = max(0.05, BrightnessService.shared.currentSoftwareBrightness(for: displayID) ?? 1.0)
        p.rHi *= brightnessFactor
        p.gHi *= brightnessFactor
        p.bHi *= brightnessFactor
        // Matches applyFormula: the boost region may rise above 1.0.
        let cap = max(1.0, brightnessFactor)

        for i in 0..<capacity {
            let input = Double(i) / Double(capacity - 1)

            func tableValue(lo: Double, hi: Double, gam: Double) -> CGGammaValue {
                let raw = lo + (hi - lo) * pow(input, gam)
                let clamped = max(0.0, min(cap, raw))
                // Quantize to `levels` discrete steps
                let stepped = floor(clamped * Double(levels)) / Double(levels)
                return CGGammaValue(stepped)
            }

            redTable[i]   = tableValue(lo: p.rLo, hi: p.rHi, gam: p.rGam)
            greenTable[i] = tableValue(lo: p.gLo, hi: p.gHi, gam: p.gGam)
            blueTable[i]  = tableValue(lo: p.bLo, hi: p.bHi, gam: p.bGam)
        }

        CGSetDisplayTransferByTable(displayID, UInt32(capacity),
                                    &redTable, &greenTable, &blueTable)
    }
}
