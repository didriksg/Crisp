import CoreGraphics
import Foundation
import ApplicationServices

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
    /// - Returns: true when both configuration and commit succeed.
    @discardableResult
    func enableMirror(
        source: CGDirectDisplayID,
        target: CGDirectDisplayID,
        expectedTargetUUID: String
    ) async -> Bool {
        // Mirroring a display onto itself is invalid and causes undefined CG behaviour.
        guard source != target else {
            return false
        }
        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            // The numeric ID is volatile. A queued transaction must not attach
            // the virtual to different hardware that inherited the ID.
            guard Self.displayUUID(for: target) == expectedTargetUUID else { return false }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            guard CGConfigureDisplayMirrorOfDisplay(cfg, target, source) == .success else {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            guard CGCompleteDisplayConfiguration(cfg, .forSession) == .success else {
                return false
            }
            return Self.displayUUID(for: target) == expectedTargetUUID
                && CGDisplayMirrorsDisplay(target) == source
        }
    }

    // MARK: - Query (source perspective)

    /// Returns true when `displayID` is acting as a mirror source, 
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
    /// This is mandatory compensating teardown: it may time out for the caller,
    /// but remains queued and reports its eventual result through the callback.
    /// - Returns: the completed result, or `.timedOut` while cleanup remains queued.
    @discardableResult
    func disableMirror(
        displayID: CGDirectDisplayID,
        expectedSource: CGDirectDisplayID,
        expectedTargetUUID: String,
        lateCompletion: @escaping @Sendable (Bool) -> Void = { _ in }
    ) async -> CGHelpers.TimedResult<Bool> {
        return await CGHelpers.runMandatoryWithTimeout(
            seconds: 10,
            operation: {
                // Resolve the stable physical target only when this mandatory
                // body reaches the front of the process-global queue. The ID
                // captured by the caller may have been reassigned meanwhile.
                guard let online = Self.onlineDisplayIDs() else { return false }
                guard let liveTarget = ([displayID] + online).first(where: {
                    online.contains($0) && Self.displayUUID(for: $0) == expectedTargetUUID
                }) else {
                    // The intended panel is gone, so it can no longer depend on
                    // our virtual master.
                    return true
                }
                // Do not disturb an unrelated mirror relationship. If the
                // intended panel no longer mirrors this exact virtual, the
                // requested pair is already dismantled.
                guard CGDisplayMirrorsDisplay(liveTarget) == expectedSource else { return true }
                var config: CGDisplayConfigRef?
                guard CGBeginDisplayConfiguration(&config) == .success,
                      let cfg = config else { return false }
                guard CGConfigureDisplayMirrorOfDisplay(
                    cfg, liveTarget, kCGNullDirectDisplay) == .success else {
                    CGCancelDisplayConfiguration(cfg)
                    return false
                }
                guard CGCompleteDisplayConfiguration(cfg, .forSession) == .success else {
                    return false
                }
                guard let refreshed = Self.onlineDisplayIDs() else { return false }
                guard let currentTarget = refreshed.first(where: {
                    Self.displayUUID(for: $0) == expectedTargetUUID
                }) else { return true }
                return CGDisplayMirrorsDisplay(currentTarget) != expectedSource
            }, lateCompletion: lateCompletion)
    }

    private static func displayUUID(for displayID: CGDirectDisplayID) -> String {
        if let cf = CGDisplayCreateUUIDFromDisplayID(displayID),
           let value = CFUUIDCreateString(nil, cf.takeRetainedValue()) {
            return value as String
        }
        return "v\(CGDisplayVendorNumber(displayID))-m\(CGDisplayModelNumber(displayID))"
            + "-s\(CGDisplaySerialNumber(displayID))"
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }
}
