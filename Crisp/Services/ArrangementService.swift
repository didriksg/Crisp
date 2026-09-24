import Foundation
import CoreGraphics

/// Service for reading and setting display positions in the global coordinate space.
/// On macOS, the display whose bounds contain origin (0, 0) is the main display
/// (the one that shows the Dock and menu bar).
@MainActor
class ArrangementService {
    static let shared = ArrangementService()
    private init() {}

    /// Moves the given display to the specified position in the global coordinate space.
    /// Used by preset restore, which writes each display's saved absolute origin.
    @discardableResult
    func setPosition(x: Int, y: Int, for displayID: CGDirectDisplayID) async -> Bool {
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
        PresetService.shared.noteManualChange()

        let dx = Int(target.bounds.origin.x)
        let dy = Int(target.bounds.origin.y)
        let origins: [(id: CGDirectDisplayID, x: Int, y: Int)] = displays.map {
            ($0.displayID, Int($0.bounds.origin.x) - dx, Int($0.bounds.origin.y) - dy)
        }
        return await applyOrigins(origins)
    }

    /// Applies origins in one atomic transaction inside `CGHelpers.runWithTimeout` so
    /// `CGCompleteDisplayConfiguration` cannot block WindowServer IPC forever.
    private func applyOrigins(_ origins: [(id: CGDirectDisplayID, x: Int, y: Int)]) async -> Bool {
        await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            for o in origins {
                CGConfigureDisplayOrigin(cfg, o.id, Int32(o.x), Int32(o.y))
            }
            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }
}
