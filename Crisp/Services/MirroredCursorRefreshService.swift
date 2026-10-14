import AppKit

/// WindowServer can leave the cursor image stale on a mirrored virtual display
/// until its desktop changes. Keep a tiny damage region on each mirror source.
/// See BetterDisplay issue #807. No cursor warps or input interception are needed.
@MainActor
final class MirroredCursorRefreshService {
    static let shared = MirroredCursorRefreshService()

    private var sourceIDs: Set<CGDirectDisplayID> = []
    private var windows: [CGDirectDisplayID: NSPanel] = [:]
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var lastPosition: NSPoint?
    private var light = false

    func setSources(_ ids: Set<CGDirectDisplayID>) {
        sourceIDs = ids
        guard !ids.isEmpty else {
            timer?.invalidate()
            timer = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            for window in windows.values { window.close() }
            windows.removeAll()
            lastPosition = nil
            return
        }
        refreshWindows()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindows() }
            }
        }
        guard timer == nil else { return }
        // Polling the position needs no Accessibility grant. Draw only on motion,
        // including departure from the source, so both cursor transitions refresh.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOnMovement() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refreshWindows() {
        let screens = NSScreen.screens.filter { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID else { return false }
            return sourceIDs.contains(id)
        }
        let liveIDs = Set(screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        })
        for id in Array(windows.keys) where !liveIDs.contains(id) {
            windows.removeValue(forKey: id)?.close()
        }
        for screen in screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID else { continue }
            let frame = NSRect(x: screen.visibleFrame.minX + 1,
                               y: screen.visibleFrame.minY + 1, width: 1, height: 1)
            let window: NSPanel
            if let existing = windows[id] {
                window = existing
                window.setFrame(frame, display: false)
            } else {
                window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.hidesOnDeactivate = false
                window.hasShadow = false
                window.isOpaque = false
                window.alphaValue = 0.01
                window.ignoresMouseEvents = true
                window.level = .statusBar
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                             .stationary, .ignoresCycle]
                window.backgroundColor = .black
                windows[id] = window
            }
            window.orderFrontRegardless()
        }
        lastPosition = nil
    }

    private func refreshOnMovement() {
        let position = NSEvent.mouseLocation
        guard position != lastPosition else { return }
        lastPosition = position
        light.toggle()
        for window in windows.values {
            window.backgroundColor = light ? .white : .black
        }
    }
}
