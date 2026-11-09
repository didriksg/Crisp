import Foundation
import CoreGraphics
import os

/// Service for reading and setting display positions in the global coordinate space.
/// On macOS, the display whose bounds contain origin (0, 0) is the main display
/// (the one that shows the Dock and menu bar).
@MainActor
class ArrangementService {
    static let shared = ArrangementService()
    private init() {}

    private static let log = Logger(subsystem: "com.crisp.app", category: "arrangement")
    private var sleepLayout: DisplayLayoutSnapshot?

    func snapshotLayoutForSleep() {
        guard let displays = currentLayout(requireActive: false) else {
            sleepLayout = nil
            return
        }
        sleepLayout = DisplayLayoutSnapshot(displays: displays)
    }

    func clearSleepLayout() {
        sleepLayout = nil
    }

    /// Mode restoration alone leaves WindowServer's smaller-set positions in place when
    /// monitors return at different times. Restore all origins together, once geometry matches.
    func restoreLayoutAfterWakeIfNeeded() async {
        guard let snapshot = sleepLayout, let current = currentLayout(requireActive: true),
              let origins = snapshot.originsToRestore(in: current) else { return }
        let ok = await applyOrigins(origins, scope: .forSession)
        Self.log.notice("layout restore after wake: \(ok ? "ok" : "failed", privacy: .public)")
    }

    private func currentLayout(requireActive: Bool) -> [DisplayLayoutSnapshot.Display]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        var displays: [DisplayLayoutSnapshot.Display] = []
        for id in ids.prefix(Int(count)) {
            guard CGDisplayIsInMirrorSet(id) == 0, !requireActive || CGDisplayIsActive(id) != 0,
                  let uuid = DisplayInfo.cgDisplayUUID(id) else { return nil }
            let bounds = CGDisplayBounds(id)
            guard bounds.width > 1, bounds.height > 1 else { return nil }
            displays.append(.init(id: id, uuid: uuid, bounds: bounds,
                                  rotation: CGDisplayRotation(id), isMain: CGDisplayIsMain(id) != 0))
        }
        return displays
    }

    /// Moves the given display to the specified position in the global coordinate space.
    /// Used by preset restore, which writes each display's saved absolute origin.
    @discardableResult
    func setPosition(x: Int, y: Int, for displayID: CGDirectDisplayID) async -> Bool {
        clearSleepLayout()
        PresetService.shared.noteManualChange()
        return await applyOrigins([(displayID, x, y)])
    }

    /// Moves `displayID` to (x, y) for an interactive drag, keeping the main display pinned
    /// at (0, 0): macOS silently renormalizes any config that leaves it off origin, so this
    /// sets every display's origin in one transaction and subtracts the main's proposed
    /// origin from all of them, matching the native Arrange Displays sheet.
    @discardableResult
    func setPosition(x: Int, y: Int, for displayID: CGDirectDisplayID,
                     among displays: [DisplayInfo]) async -> Bool {
        clearSleepLayout()
        PresetService.shared.noteManualChange()

        // Proposed origins: everyone keeps their spot except the dragged display.
        var origins: [(id: CGDirectDisplayID, x: Int, y: Int)] = displays.map { d in
            d.displayID == displayID
                ? (d.displayID, x, y)
                : (d.displayID, Int(d.bounds.origin.x), Int(d.bounds.origin.y))
        }
        // Renormalize so the current main sits at (0, 0). When the main is the
        // dragged display, this pushes its offset onto all the others.
        if let mainID = displays.first(where: { $0.isMain })?.displayID,
           let main = origins.first(where: { $0.id == mainID }),
           main.x != 0 || main.y != 0 {
            let dx = main.x, dy = main.y
            origins = origins.map { ($0.id, $0.x - dx, $0.y - dy) }
        }
        return await applyOrigins(origins)
    }

    /// Makes the target the main display by translating every display by the same vector,
    /// so the relative arrangement is preserved and only the origin moves; swapping just the
    /// target and old-main origins (the previous approach) could overlap a wider display.
    @discardableResult
    func setAsMainDisplay(_ targetID: CGDirectDisplayID, among displays: [DisplayInfo]) async -> Bool {
        guard let target = displays.first(where: { $0.displayID == targetID }),
              !target.isMain else {
            return false
        }
        clearSleepLayout()
        PresetService.shared.noteManualChange()

        let dx = Int(target.bounds.origin.x)
        let dy = Int(target.bounds.origin.y)
        let origins: [(id: CGDirectDisplayID, x: Int, y: Int)] = displays.map {
            ($0.displayID, Int($0.bounds.origin.x) - dx, Int($0.bounds.origin.y) - dy)
        }
        return await applyOrigins(origins)
    }

    /// Applies origins in one atomic transaction inside `CGHelpers.runWithTimeout` so
    /// `CGCompleteDisplayConfiguration` cannot block WindowServer IPC forever. User actions
    /// commit permanently (#193); a wake repair only changes the current session.
    private func applyOrigins(
        _ origins: [(id: CGDirectDisplayID, x: Int, y: Int)],
        scope: CGConfigureOption = .permanently
    ) async -> Bool {
        await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            for o in origins {
                guard CGConfigureDisplayOrigin(cfg, o.id, Int32(o.x), Int32(o.y)) == .success else {
                    CGCancelDisplayConfiguration(cfg)
                    return false
                }
            }
            let result = CGCompleteDisplayConfiguration(cfg, scope)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }
}
