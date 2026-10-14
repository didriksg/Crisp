// Command Line Tools-only lifecycle check; briefly creates a one-point panel.
// swiftc -swift-version 6 -parse-as-library Crisp/Services/MirroredCursorRefreshService.swift \
//   scripts/check-mirrored-cursor-refresh.swift -o /tmp/crisp-cursor-checks && /tmp/crisp-cursor-checks
import AppKit

@main
struct MirroredCursorRefreshChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let service = MirroredCursorRefreshService.shared
        defer { service.setSources([]) }
        let screen = NSScreen.screens.first!
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let initialWindows = Set(app.windows.map(ObjectIdentifier.init))
        func overlays() -> [NSWindow] {
            app.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) && $0.isVisible }
        }
        service.setSources([id])
        precondition(overlays().count == 1)
        let window = overlays()[0]
        precondition(window.ignoresMouseEvents && !window.isKeyWindow && !window.isMainWindow)
        precondition(window.frame.size == NSSize(width: 1, height: 1))
        precondition(screen.frame.contains(window.frame))
        service.setSources([id])
        precondition(overlays().count == 1 && overlays()[0] === window)
        service.setSources([UInt32.max])
        precondition(overlays().isEmpty, "A vanished source retained an overlay")
        service.setSources([id])
        precondition(overlays().count == 1)
        service.setSources([])
        precondition(overlays().isEmpty, "Stopping mirroring left an overlay visible")
        service.setSources([])
        precondition(overlays().isEmpty)
        print("PASS: overlay creation, click-through, placement, reuse, disappearance, restart, cleanup")
    }
}
