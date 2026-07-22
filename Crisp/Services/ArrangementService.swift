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
    /// The entire Begin→Origin→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    /// - Returns: true if the configuration was applied successfully.
    @discardableResult
    func setPosition(x: Int, y: Int, for displayID: CGDirectDisplayID) async -> Bool {
        PresetService.shared.noteManualChange()
        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            CGConfigureDisplayOrigin(cfg, displayID, Int32(x), Int32(y))
            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }

    /// Makes the target display the main display by moving it to origin (0, 0).
    /// Moves the current main display to the position previously occupied by the target.
    /// The entire Begin→Origin→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    /// - Returns: true if the configuration was applied successfully.
    @discardableResult
    func setAsMainDisplay(_ targetID: CGDirectDisplayID, among displays: [DisplayInfo]) async -> Bool {
        guard let target = displays.first(where: { $0.displayID == targetID }),
              let currentMain = displays.first(where: { $0.isMain }),
              currentMain.displayID != targetID else {
            return false
        }
        PresetService.shared.noteManualChange()

        // Capture value types only — no OpaquePointer crossing the @Sendable boundary.
        let targetOriginX = Int32(target.bounds.origin.x)
        let targetOriginY = Int32(target.bounds.origin.y)
        let currentMainID = currentMain.displayID

        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }

            // Move target to origin → it becomes the new main display
            CGConfigureDisplayOrigin(cfg, targetID, 0, 0)

            // Move old main to where the target was.
            CGConfigureDisplayOrigin(cfg, currentMainID, targetOriginX, targetOriginY)

            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }
}
