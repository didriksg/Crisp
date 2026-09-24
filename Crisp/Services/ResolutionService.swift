import Foundation
@preconcurrency import CoreGraphics
import ColorSync // CGDisplayCreateUUIDFromDisplayID
import os

// CGDisplayMode isn't Sendable; needed to pass a main-actor-read mode to the nonisolated
// apply path (same reason as VirtualDisplayService's CGVirtualDisplay conformances).
extension CGDisplayMode: @unchecked @retroactive Sendable {}

/// Reads and changes display resolution modes. See docs/display-notes.md (ResolutionService).
@MainActor
final class ResolutionService: @unchecked Sendable {
    static let shared = ResolutionService()
    private init() {
        // Stale key from the old always-remember store this replaced; clearing it prevents
        // a future reader resurrecting a preference the user never set for this display set.
        UserDefaults.standard.removeObject(forKey: "crisp.ResolutionService.savedModesByUUID")
    }

    nonisolated private static let log = Logger(subsystem: "com.crisp.app", category: "display")

    /// Held by attributes, not the volatile ioDisplayModeID, which macOS reassigns whenever
    /// the mode list rebuilds. See docs/display-notes.md (ResolutionService). (w18z)
    private struct SavedMode: Equatable {
        let width: Int
        let height: Int
        let refresh: Double
        let hidpi: Bool
    }

    /// Each active display's mode as the screens went to sleep, keyed by uuid; lives for
    /// one sleep only. See docs/display-notes.md (ResolutionService).
    private var sleepModes: [String: SavedMode]?

    /// Records what every display is at, called as the screens go to sleep.
    func snapshotModesForSleep() {
        var snapshot: [String: SavedMode] = [:]
        for displayID in Self.onlineDisplayIDs() {
            guard let key = Self.uuidKey(for: displayID),
                  let mode = CGDisplayCopyDisplayMode(displayID) else { continue }
            snapshot[key] = SavedMode(width: mode.width, height: mode.height,
                                      refresh: mode.refreshRate, hidpi: mode.pixelWidth > mode.width)
        }
        sleepModes = snapshot
        Self.log.notice("screens asleep: remembered \(snapshot.count, privacy: .public) display mode(s)")
    }

    /// Online, not active: a display keeps its mode while it sleeps but drops out
    /// of the active list, and the snapshot is taken exactly as that happens.
    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// nil while the display is disabled: CGDisplayCreateUUIDFromDisplayID has no uuid for it then.
    private static func uuidKey(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String
    }

    /// Match within 1 Hz (macOS reports fractional rates like 59.97 for a stored 60); 0 means
    /// "display default" and matches anything.
    static func refreshMatches(_ a: Double, _ b: Double) -> Bool {
        if a == 0 || b == 0 { return true }
        return abs(a - b) < 1.0
    }

    /// Restores the pre-sleep mode if macOS brought the display back on a different one; skips
    /// rather than forces a fallback when the exact size no longer exists. (w18z)
    /// See docs/display-notes.md (ResolutionService).
    func restoreModeAfterWakeIfNeeded(for displayID: CGDirectDisplayID) {
        // A mirrored beyond-cap size (#65) belongs to MirroredModeService to restore, not us.
        guard !MirroredModeService.shared.isActive(for: displayID) else { return }
        guard let snapshot = sleepModes, let key = Self.uuidKey(for: displayID),
              let saved = snapshot[key] else { return }

        // Display set changed while asleep (different desk); skip rather than clear, since
        // a later wake pass may still see the old set again.
        guard Set(snapshot.keys) == Set(Self.onlineDisplayIDs().compactMap(Self.uuidKey(for:))) else { return }

        // Already at the saved resolution? Nothing to do.
        if let cur = CGDisplayCopyDisplayMode(displayID),
           cur.width == saved.width, cur.height == saved.height,
           (cur.pixelWidth > cur.width) == saved.hidpi,
           Self.refreshMatches(cur.refreshRate, saved.refresh) {
            return
        }

        // Mirror targets can't take CGConfigureDisplayWithDisplayMode; apply to the source
        // instead, same as setDisplayMode. See docs/display-notes.md (ResolutionService).
        let (targetID, _) = resolvedTargetDisplayID(for: displayID)

        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let rawModes = CGDisplayCopyAllDisplayModes(targetID, options) as? [CGDisplayMode],
              let cgMode = rawModes.first(where: {
                  $0.width == saved.width && $0.height == saved.height &&
                  ($0.pixelWidth > $0.width) == saved.hidpi &&
                  Self.refreshMatches($0.refreshRate, saved.refresh)
              })
        else { return }

        let now = CGDisplayCopyDisplayMode(displayID)
        Self.log.notice("display \(displayID, privacy: .public): came back from sleep on \(now?.width ?? 0, privacy: .public)x\(now?.height ?? 0, privacy: .public), restoring the pre-sleep \(saved.width, privacy: .public)x\(saved.height, privacy: .public) @\(Int(saved.refresh), privacy: .public)")
        Task.detached(priority: .userInitiated) {
            let ok = await ResolutionService.applyModeSync(cgMode, on: targetID)
            ResolutionService.log.notice("display \(displayID, privacy: .public): mode restore after wake \(ok ? "ok" : "failed", privacy: .public)")
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

    /// Sets a display mode; mirror-aware (applies to the mirror source, not target).
    /// See docs/display-notes.md (ResolutionService).
    func setDisplayMode(_ mode: DisplayMode, for displayID: CGDirectDisplayID) async -> Bool {
        PresetService.shared.noteManualChange()
        let (targetID, isMirrorRedirect) = resolvedTargetDisplayID(for: displayID)
        let scope = DisplayModeCommitScope.forUserSelection(
            isVirtualDisplay: isMirrorRedirect || VirtualDisplayService.shared.isVirtualDisplay(targetID)
        )

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

            // Second try: size+HiDPI match, but only on a mirror redirect (different modeID
            // space). For a normal display a missing id is a CGS hidden mode; size-matching
            // there would wrongly pick CG's low-refresh twin, so fall through to CGS instead.
            return isMirrorRedirect ? ResolutionService.bestMatchingMode(in: allRaw, for: mode) : nil
        }.value

        guard let cgMode else {
            // No CGDisplayMode with this id: a CGS-hidden HiDPI variant, or the mirror-source
            // last resort. Both apply through the CGS transaction API.
            return await cgsFallback(modeID: UInt32(bitPattern: mode.ioDisplayModeID), on: targetID, scope: scope)
        }

        // Apply via standard public CG API (off main thread to avoid blocking the UI)
        let success = await Task.detached(priority: .userInitiated) {
            await ResolutionService.applyModeSync(cgMode, on: targetID, scope: scope)
        }.value

        if success { return true }

        // Fallback: CGSConfigureDisplayMode
        return await cgsFallback(modeID: UInt32(bitPattern: cgMode.ioDisplayModeID), on: targetID, scope: scope)
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

    /// Best CGDisplayMode match for `mode`'s logical size, preferring an exact HiDPI-flag match.
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

    /// Applies a mode change off the calling thread; the whole Begin/Configure/Complete
    /// transaction runs inside `CGHelpers.runWithTimeout` so it cannot block WindowServer IPC forever.
    nonisolated static func applyModeSync(
        _ cgMode: CGDisplayMode,
        on displayID: CGDirectDisplayID,
        scope: CGConfigureOption = .forSession
    ) async -> Bool {
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

            let complete = CGCompleteDisplayConfiguration(cfg, scope)
            return complete == .success
        }
    }

    // MARK: - CGSConfigureDisplayMode fallback (private API)

    /// Applies a mode by raw modeNumber via the private CGS API; reaches GPU-scaled HiDPI
    /// variants CG hides. See docs/display-notes.md (ResolutionService).
    private func cgsFallback(
        modeID: UInt32,
        on displayID: CGDirectDisplayID,
        scope: CGConfigureOption
    ) async -> Bool {
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

            return CGCompleteDisplayConfiguration(cfg, scope) == .success
        }.value
        guard committed else { return false }
        // Commit propagates async; wait for the mode-change event (not a blind sleep) then verify.
        let target = Int32(bitPattern: modeID)
        if CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID == target { return true }
        await ReconfigEvents.shared.next(for: displayID, matching: .setModeFlag, timeout: 0.5)
        return CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID == target
    }
}
