import CoreGraphics
import Foundation

/// Provides hardware-level screen mirroring via CGDisplayConfiguration API.
final class MirrorService: @unchecked Sendable {
    static let shared = MirrorService()
    private init() {}

    // MARK: - Query

    /// Returns the source display that `displayID` is mirroring, or nil if not mirroring.
    func mirrorSource(for displayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        let source = CGDisplayMirrorsDisplay(displayID)
        guard source != kCGNullDirectDisplay else { return nil }
        return source
    }

    /// Returns true when `displayID` is currently mirroring another display.
    func isMirroring(_ displayID: CGDirectDisplayID) -> Bool {
        mirrorSource(for: displayID) != nil
    }

    // MARK: - Enable

    /// Makes `target` mirror `source`.
    /// The entire Begin→Mirror→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    /// - Returns: true on success.
    @discardableResult
    func enableMirror(source: CGDirectDisplayID, target: CGDirectDisplayID) async -> Bool {
        // Mirroring a display onto itself is invalid and causes undefined CG behaviour.
        guard source != target else {
#if DEBUG
            print("[MirrorService] enableMirror: source == target (\(source)), ignoring")
#endif
            return false
        }
        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            CGConfigureDisplayMirrorOfDisplay(cfg, target, source)
            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }

    // MARK: - Query (source perspective)

    /// Returns true when `displayID` is acting as a mirror source —
    /// i.e., at least one other online display is cloning it.
    func isMirrorSource(_ displayID: CGDirectDisplayID) -> Bool {
        mirrorTargets(of: displayID) != nil
    }

    /// Returns the first display that is mirroring `sourceID`, or nil if none.
    func mirrorTargets(of sourceID: CGDirectDisplayID) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.first { $0 != sourceID && CGDisplayMirrorsDisplay($0) == sourceID }
    }

    // MARK: - Disable

    /// Stops `displayID` from mirroring.
    /// The entire Begin→Mirror→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    /// - Returns: true on success.
    @discardableResult
    func disableMirror(displayID: CGDirectDisplayID) async -> Bool {
        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            CGConfigureDisplayMirrorOfDisplay(cfg, displayID, kCGNullDirectDisplay)
            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }
}
