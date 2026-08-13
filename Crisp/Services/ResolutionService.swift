import Foundation
@preconcurrency import CoreGraphics

/// Service responsible for reading and changing display resolution modes.
@MainActor
final class ResolutionService: @unchecked Sendable {
    static let shared = ResolutionService()
    private init() {}

    /// A persisted resolution stored as ATTRIBUTES, not the volatile ioDisplayModeID. macOS
    /// reassigns that raw ID whenever the mode list is rebuilt (HiDPI override inject/remove,
    /// reconnect, sleep/wake), so matching by ID after a rebuild resolved to a DIFFERENT mode
    /// and set a wrong (often off-aspect, 60Hz) resolution on wake. (w18z)
    private struct SavedMode: Codable, Equatable {
        let width: Int
        let height: Int
        let refresh: Double
        let hidpi: Bool
    }

    private static let savedModesKey = "crisp.ResolutionService.savedModeAttrs"

    /// Last user-set mode per displayID (string key). Used to re-apply modes after sleep/wake.
    private var savedModes: [String: SavedMode] = {
        guard let data = UserDefaults.standard.data(forKey: ResolutionService.savedModesKey),
              let decoded = try? JSONDecoder().decode([String: SavedMode].self, from: data)
        else { return [:] }
        return decoded
    }()

    private func persistMode(_ mode: DisplayMode, for displayID: CGDirectDisplayID) {
        savedModes["\(displayID)"] = SavedMode(width: mode.width, height: mode.height,
                                               refresh: mode.refreshRate, hidpi: mode.isHiDPI)
        UserDefaults.standard.set(try? JSONEncoder().encode(savedModes), forKey: Self.savedModesKey)
    }

    /// Refresh rates match within 1 Hz (macOS reports 59.97 for a stored 60, etc., and the
    /// CGS-surfaced hidden modes carry whole-Hz uint16 rates while CG modes carry fractional
    /// ones). A 0 means "display default"; treat it as a wildcard so it never blocks an
    /// otherwise exact resolution match.
    static func refreshMatches(_ a: Double, _ b: Double) -> Bool {
        if a == 0 || b == 0 { return true }
        return abs(a - b) < 1.0
    }

    /// Re-applies the last user-set mode for `displayID` if it differs from the current active
    /// mode. Called on wake from sleep so macOS mode resets are corrected. Matches by attributes
    /// and applies ONLY on an exact match in the current valid mode list; if the saved size no
    /// longer exists (mode list rebuilt, display swapped) it does nothing rather than forcing an
    /// off-aspect fallback. (w18z)
    func reapplySavedModeIfNeeded(for displayID: CGDirectDisplayID) {
        guard let saved = savedModes["\(displayID)"] else { return }

        // Already at the saved resolution? Nothing to do.
        if let cur = CGDisplayCopyDisplayMode(displayID),
           cur.width == saved.width, cur.height == saved.height,
           (cur.pixelWidth > cur.width) == saved.hidpi,
           Self.refreshMatches(cur.refreshRate, saved.refresh) {
            return
        }

        // Mirror targets can't take CGConfigureDisplayWithDisplayMode (it silently hangs or
        // fails; their mode is driven by the source), so apply to the mirror source, same as
        // setDisplayMode.
        let (targetID, _) = resolvedTargetDisplayID(for: displayID)

        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let rawModes = CGDisplayCopyAllDisplayModes(targetID, options) as? [CGDisplayMode],
              let cgMode = rawModes.first(where: {
                  $0.width == saved.width && $0.height == saved.height &&
                  ($0.pixelWidth > $0.width) == saved.hidpi &&
                  Self.refreshMatches($0.refreshRate, saved.refresh)
              })
        else { return }

        Task.detached(priority: .userInitiated) {
            _ = await ResolutionService.applyModeSync(cgMode, on: targetID)
        }
    }

    // MARK: - Query

    func availableModes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
        DisplayMode.availableModes(for: displayID)
    }

    func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
        DisplayMode.currentMode(for: displayID)
    }

    // MARK: - Apply

    /// Sets a display mode on `displayID`.
    ///
    /// Mirror-aware: when the target display is a mirror target (e.g. the physical display
    /// is mirroring a CGVirtualDisplay for HiDPI), the mode must be applied to the mirror
    /// SOURCE (the virtual display), not to the mirror target itself.
    /// CGConfigureDisplayWithDisplayMode silently hangs or fails on mirror targets because
    /// their mode is driven by the source.
    ///
    /// Strategy:
    ///   1. If displayID is a mirror target, resolve to the mirror source (virtualDisplayID).
    ///   2. Find the matching CGDisplayMode on the source by logical size + HiDPI attributes.
    ///   3. Apply via CGConfigureDisplayWithDisplayMode on the source display.
    ///   4. Fallback: try CGSConfigureDisplayMode (private API) on the source.
    func setDisplayMode(_ mode: DisplayMode, for displayID: CGDirectDisplayID) async -> Bool {
        PresetService.shared.noteManualChange()
        // Resolve mirror source, the physical display may mirror a virtual display
        let (targetID, isMirrorRedirect) = resolvedTargetDisplayID(for: displayID)

        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary

        // Enumerate modes off the main thread to avoid blocking the UI
        let cgMode: CGDisplayMode? = await Task.detached(priority: .userInitiated) {
            guard let allRaw = CGDisplayCopyAllDisplayModes(targetID, options) as? [CGDisplayMode] else {
                return nil
            }

            // First try: exact modeID match (works when targetID == displayID)
            if let exact = allRaw.first(where: { $0.ioDisplayModeID == mode.ioDisplayModeID }) {
                return exact
            }

            // Second try: match by logical size + HiDPI ONLY on a mirror redirect (the source has
            // a different modeID space than the mirror target). For a normal display, an id missing
            // from CG's list is a CGS-injected hidden mode (e.g. the 144Hz HiDPI-1080p variant):
            // size-matching would wrongly pick CG's low-refresh twin (the real 4K@50 timing), so
            // fall through to the CGS apply path instead.
            return isMirrorRedirect ? ResolutionService.bestMatchingMode(in: allRaw, for: mode) : nil
        }.value

        guard let cgMode else {
            // No CGDisplayMode with this id: the GPU-scaled HiDPI variant CG hides (surfaced from
            // the CGS list), or the mirror-source last resort. Both apply via the CGS transaction
            // API, which addresses modes by the same id (CGS modeNumber == ioDisplayModeID).
            let ok = await cgsFallback(modeID: UInt32(bitPattern: mode.ioDisplayModeID), on: targetID)
            if ok { persistMode(mode, for: displayID) }
            return ok
        }

        // Apply via standard public CG API (off main thread to avoid blocking the UI)
        let success = await Task.detached(priority: .userInitiated) {
            await ResolutionService.applyModeSync(cgMode, on: targetID)
        }.value

        if success {
            // Persist so we can re-apply after sleep/wake
            persistMode(mode, for: displayID)
            return true
        }

        // Fallback: CGSConfigureDisplayMode
        let fallbackSuccess = await cgsFallback(modeID: UInt32(bitPattern: cgMode.ioDisplayModeID), on: targetID)
        if fallbackSuccess {
            persistMode(mode, for: displayID)
        }
        return fallbackSuccess
    }

    // MARK: - Mirror resolution

    /// Returns the display ID that should receive the mode change, plus a flag indicating
    /// whether a mirror redirect occurred.
    private func resolvedTargetDisplayID(for displayID: CGDirectDisplayID) -> (CGDirectDisplayID, Bool) {
        let mirrorSource = CGDisplayMirrorsDisplay(displayID)
        guard mirrorSource != kCGNullDirectDisplay else {
            return (displayID, false)
        }

        // Verify the source exists and has modes
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let sourceModes = CGDisplayCopyAllDisplayModes(mirrorSource, options) as? [CGDisplayMode],
              !sourceModes.isEmpty else {
            return (displayID, false)
        }

        return (mirrorSource, true)
    }

    // MARK: - Mode attribute matching

    /// Find the best CGDisplayMode in `rawModes` matching `mode`'s logical properties.
    ///
    /// Matching priority:
    ///   1. Exact logical size + HiDPI flag (pixel > logical)
    ///   2. Exact logical size (any HiDPI)
    nonisolated static func bestMatchingMode(in rawModes: [CGDisplayMode], for mode: DisplayMode) -> CGDisplayMode? {
        // Exact logical size + HiDPI
        let exact = rawModes.first(where: {
            $0.width == mode.width &&
            $0.height == mode.height &&
            ($0.pixelWidth > $0.width) == mode.isHiDPI &&
            $0.isUsableForDesktopGUI()
        })
        if let m = exact { return m }

        // Relax HiDPI constraint
        return rawModes.first(where: {
            $0.width == mode.width &&
            $0.height == mode.height &&
            $0.isUsableForDesktopGUI()
        })
    }

    // MARK: - Commit via public CG API (async, call off main thread)

    /// Applies a display mode change off the calling thread.
    /// The entire Begin→Configure→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    nonisolated static func applyModeSync(_ cgMode: CGDisplayMode, on displayID: CGDirectDisplayID) async -> Bool {
        await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else {
                return false
            }

            let result = CGConfigureDisplayWithDisplayMode(cfg, displayID, cgMode, nil)
            guard result == .success else {
                CGCancelDisplayConfiguration(cfg)
                return false
            }

            let complete = CGCompleteDisplayConfiguration(cfg, .forSession)
            return complete == .success
        }
    }

    // MARK: - CGSConfigureDisplayMode fallback (private API)

    /// Applies a mode by its raw modeNumber using the CGS private API. Reaches the GPU-scaled
    /// HiDPI variants CG hides (e.g. 1920x1080 HiDPI @144Hz) that CGConfigureDisplayWithDisplayMode
    /// cannot see, and mirror-source modes.
    ///
    /// CGSConfigureDisplayMode's first argument is a CONFIG TOKEN from CGBeginDisplayConfiguration,
    /// NOT the connection id: it reads the argument as a CGSConfigData*, so passing the connection
    /// id segfaults in checkCapacity() on macOS 26. It must run inside a real
    /// CGBegin/CGCompleteDisplayConfiguration transaction (verified against BetterDisplay on Tahoe).
    private func cgsFallback(modeID: UInt32, on displayID: CGDirectDisplayID) async -> Bool {
        let committed = await Task.detached(priority: .userInitiated) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
                return false
            }

            let result = CGSConfigureDisplayMode(cfg, displayID, Int32(bitPattern: modeID))
            guard result == .success else {
                CGCancelDisplayConfiguration(cfg)
                return false
            }

            return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        }.value
        guard committed else { return false }
        // The commit propagates async. Fast path: already active. Otherwise wait
        // for the mode-change event instead of a blind 100ms sleep (0.5s ceiling
        // also covers panels the old flat sleep verified too early on), then
        // verify the active mode actually changed.
        let target = Int32(bitPattern: modeID)
        if CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID == target { return true }
        await ReconfigEvents.shared.next(for: displayID, matching: .setModeFlag, timeout: 0.5)
        return CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID == target
    }
}
