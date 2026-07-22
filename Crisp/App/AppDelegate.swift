import AppKit
import SwiftUI
import CoreGraphics

/// Borderless key-capable panel for the menu bar UI.
/// Owning the panel (instead of MenuBarExtra's window) removes the WindowServer
/// zoom-in materialization and gives us native-menu open behavior.
final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// While set, every frame change re-anchors to this top edge (screen Y of
    /// the panel top). AppKit windows anchor bottom-left, so the auto-resize
    /// from the hosting view would otherwise grow the panel upward.
    var pinnedTopY: CGFloat?

    /// The SwiftUI hosting view inside the container content view.
    weak var hostingView: NSView?
    /// Last content size reported by SwiftUI layout (source of truth for
    /// the panel's natural size when showing).
    var lastContentSize: NSSize?
    private var resizeTimer: Timer?
    private var resizeTarget: NSSize?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var r = frameRect
        if let top = pinnedTopY { r.origin.y = top - r.height }
        super.setFrame(r, display: flag)
    }

    func applyContentSize(_ size: NSSize) {
        lastContentSize = size
        // Already animating toward this exact size: let the spring finish.
        if let t = resizeTarget, resizeTimer?.isValid == true,
           abs(t.height - size.height) < 0.5, abs(t.width - size.width) < 0.5 { return }
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        resizeTimer?.invalidate()
        resizeTarget = nil

        // Hidden (alpha 0) means warm-up layout: snap so the panel opens at
        // full size instantly.
        if alphaValue == 0 {
            var f = frame
            f.size = size
            setFrame(f, display: false)
            return
        }

        // SwiftUI's onGeometryChange reports only the final model height (one
        // callback per change, no animation frames), so the eased motion can't
        // be measured out of the layout. Instead the window runs the SAME
        // spring the content runs: Animation.smooth(duration:) is a critically
        // damped spring, x(t) = T + (x0-T)(1 + wt)e^(-wt) with w = 2*pi/d.
        // Same curve, same duration, started in the same runloop turn ->
        // window edge and curtain land on the same value every frame.
        // Main-thread timer, not animator(): NSWindow's frame animator runs on
        // a background thread and tears reads of pinnedTopY.
        let duration = Animation.panelResizeDuration
        let omega = 2 * Double.pi / duration
        let from = frame.size
        let start = CACurrentMediaTime()
        resizeTarget = size
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let dt = CACurrentMediaTime() - start
            let decay = (1 + omega * dt) * exp(-omega * dt)
            var f = self.frame
            if decay < 0.005 {
                t.invalidate()
                self.resizeTarget = nil
                f.size = size
            } else {
                f.size = NSSize(width: size.width + (from.width - size.width) * decay,
                                height: size.height + (from.height - size.height) * decay)
            }
            self.setFrame(f, display: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var clickMonitor: Any?

    let displayManager = DisplayManager()
    private var statusItem: NSStatusItem?
    private var panel: MenuPanel?
    /// The panel is NEVER ordered out once warmed: taking the backdrop surface
    /// off screen makes WindowServer replay its materialize bloom (the growing
    /// rectangle) on every reopen. Hidden = alpha 0 + click-through instead,
    /// so track shown-ness ourselves; isVisible stays true.
    private var isPanelShown = false

    /// Called after wake-from-sleep; wired in setupStartupBehavior.
    var onWake: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate launch via an exclusive file lock. Unlike consulting
        // NSWorkspace (whose entries linger during teardown and race with fast
        // relaunches), flock is released by the kernel the moment a process dies.
        let lockPath = NSTemporaryDirectory() + "crisp.lock"
        let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if lockFD == -1 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            print("[Crisp] Another instance is already running, exiting.")
            exit(0)
        }
        // The descriptor stays open for the app's lifetime to hold the lock.

        // Start intercepting brightness keys to route them to the display under the cursor.
        BrightnessKeyService.shared.start()

        // Touch the singleton so auto-brightness polling starts at launch; otherwise
        // it only starts the first time the menu panel is opened (its only other ref).
        _ = AutoBrightnessService.shared

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onWake?()
        }

        setupStartupBehavior()
        setupStatusItem()

        // Re-anchor the open panel when screens change: switching the main
        // display re-origins global coordinates, which would otherwise leave
        // the panel floating at a stale position.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPanelShown, let p = self.panel else { return }
                self.positionPanel(p)
                // Reconfiguration settles in phases; anchor once more after.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, self.isPanelShown, let p = self.panel else { return }
                    self.positionPanel(p)
                }
            }
        }

        // Pre-warm the panel while hidden so the very first open, like every
        // reopen, appears at its final, settled size (fittingSize is only an
        // estimate; real layout can differ by a few points).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.warmPanel()
        }

    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        BrightnessKeyService.shared.stop()
        // GammaService already handles CGDisplayRestoreColorSyncSettings via willTerminateNotification observer.
        VirtualDisplayService.shared.destroyAll()
    }

    // MARK: - Startup behavior (previously in CrispApp's task)

    private func setupStartupBehavior() {
        // Launching must never touch display state the user didn't ask for
        // (the inherited auto-arrange-external-above-builtin is gone).
        onWake = { [weak self] in
            guard let dm = self?.displayManager else { return }
            Task { @MainActor in
                // Give WindowServer 2 seconds to stabilize after wake before
                // touching display state.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                dm.refreshDisplays()
                try? await Task.sleep(nanoseconds: 500_000_000)
                for display in dm.displays {
                    // Apply software brightness factor first so GammaService
                    // can read the up-to-date factor when it re-applies its formula.
                    BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                    GammaService.shared.reapplyIfNeeded(for: display.displayID)
                    // Re-apply any custom resolution that macOS may have reset on wake
                    ResolutionService.shared.reapplySavedModeIfNeeded(for: display.displayID)
                }
            }
        }
    }

    // MARK: - Status item + panel

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "display", accessibilityDescription: "Crisp")
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
    }

    private var isWarmed = false

    private func warmPanel() {
        let p = panel ?? makePanel()
        panel = p
        guard !isWarmed else { return }
        isWarmed = true
        // The hosting view lives INSIDE a plain container, never as the
        // window contentView: as contentView, NSHostingView installs its own
        // window-sizing machinery that snaps the frame back to content size
        // on every layout pass, fighting the unfurl and any manual resize.
        let hosting = NSHostingView(rootView: PanelRootView(displayManager: displayManager))
        let size = hosting.fittingSize
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        // Clip the whole container to the panel shape: the glass view's
        // square bounds otherwise peek past the rounded corners (double edge).
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true
        // The menu backdrop fills the WINDOW (not the content), so while the
        // window height animates the glass always reaches the bottom edge.
        // macOS 26 Liquid Glass, the material Control Center panels actually
        // use (no NSVisualEffectView grade matches it). Its materialize bloom
        // plays only when the view first comes on screen, which happens once
        // during hidden warm-up; the panel never orders out afterwards.
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.cornerRadius = 16
            backdrop = glass
        } else {
            // Pre-Tahoe: .popover is the translucent grade native menus and
            // Control Center panels show on macOS 15.
            let material = NSVisualEffectView(frame: container.bounds)
            material.material = .popover
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 16
            material.layer?.masksToBounds = true
            backdrop = material
        }
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)
        // The hosting view is a fixed, oversized canvas glued to the window
        // top and extending far past the bottom edge; the window edge simply
        // reveals or clips it. Because it NEVER resizes with the window,
        // animated height changes cause zero SwiftUI re-layout and no
        // transient content shifts at the top.
        let canvasHeight: CGFloat = 2400
        hosting.frame = NSRect(x: 0, y: container.bounds.height - canvasHeight,
                               width: size.width, height: canvasHeight)
        hosting.autoresizingMask = [.minYMargin]
        container.addSubview(hosting)
        p.hostingView = hosting
        p.lastContentSize = size
        p.setFrame(NSRect(origin: NSPoint(x: 0, y: -4000), size: size), display: false)
        p.contentView = container
        p.layoutIfNeeded()
        // Bring the surface on screen invisibly so the backdrop's one-time
        // materialize animation plays now, while nobody can see it.
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        p.orderFrontRegardless()
    }

    @objc private func togglePanel() {
        if isPanelShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    /// Anchors the panel under the status item on whatever screen it lives
    /// on. Called on open AND whenever screen parameters change (e.g. the
    /// main display switches, which re-origins global coordinates and would
    /// otherwise leave the panel at a stale position).
    private func positionPanel(_ p: MenuPanel) {
        let size = p.lastContentSize ?? p.frame.size
        guard let btnWindow = statusItem?.button?.window else { return }
        let btnFrame = btnWindow.frame
        let screen = btnWindow.screen ?? NSScreen.main
        var x = btnFrame.midX - size.width / 2
        if let vis = screen?.visibleFrame {
            x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        }
        let topY = btnFrame.minY - 4
        if let vis = screen?.visibleFrame {
            // The panel may grow to just short of the screen bottom before
            // its content starts scrolling.
            PanelMetrics.maxContentHeight = max(400, topY - vis.minY - 40)
        }
        p.pinnedTopY = nil
        p.setFrame(NSRect(x: x, y: topY - size.height, width: size.width, height: size.height),
                   display: false)
        p.pinnedTopY = topY
    }

    private func showPanel() {
        // Content stays alive across opens (warm is a no-op after the first
        // call) so nothing mounts or animates in at open time; per-open state
        // refresh happens below instead.
        warmPanel()
        guard let p = panel else { return }

        // Native menus appear at full size with all content visible at once;
        // only size changes AFTER opening animate.
        positionPanel(p)

        p.ignoresMouseEvents = false
        // Duration-zero animator set replaces any in-flight close fade.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            p.animator().alphaValue = 1
        }
        p.orderFrontRegardless()
        p.makeKey()
        isPanelShown = true

        PanelOpenGuard.openedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isPanelShown else { return }
            CoreBrightnessService.shared.refresh()
            for display in self.displayManager.displays {
                Task { await BrightnessService.shared.refreshBrightness(for: display) }
            }
        }

        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let p = self.panel else { return }
                    // Global monitors normally fire only for clicks landing in
                    // OTHER apps (= outside the panel). But during the dark
                    // mode crossfade the system's snapshot overlay intercepts
                    // every click, so an inside click arrives here too; close
                    // only when the cursor is genuinely outside the panel.
                    if p.frame.contains(NSEvent.mouseLocation) { return }
                    self.closePanel()
                }
            }
        }
    }

    private func closePanel() {
        guard let p = panel, isPanelShown else { return }
        isPanelShown = false
        // Hide with a quick fade, like native menus; never order out (see
        // isPanelShown comment). Click-through is immediate.
        p.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 0
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func makePanel() -> MenuPanel {
        let p = MenuPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.transient, .ignoresCycle]
        p.delegate = self
        p.onCancel = { [weak self] in self?.closePanel() }
        return p
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? MenuPanel) === panel {
            // Same overlay caveat as the click monitor: during the crossfade
            // the snapshot window can steal key while the user is clicking
            // INSIDE the panel; don't treat that as clicking away.
            if let p = panel, p.frame.contains(NSEvent.mouseLocation) { return }
            closePanel()
        }
    }
}

/// Root SwiftUI view of the panel: menu content on the system glass backdrop.
struct PanelRootView: View {
    let displayManager: DisplayManager

    var body: some View {
        // Top-aligned inside the window: if window and content ever disagree,
        // the excess window area is transparent below the glass instead of an
        // empty glass gap above the content.
        VStack(spacing: 0) {
            MenuBarView()
                .environmentObject(displayManager)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { size in
                    // Resize the window synchronously with content layout so the
                    // two can never disagree. MenuPanel re-anchors every frame
                    // change to its pinned top, so growth goes downward.
                    guard size.width > 0, size.height > 0,
                          let w = NSApp.windows.first(where: { $0 is MenuPanel }) as? MenuPanel else { return }
                    w.applyContentSize(size)
                }
        }
        // Top-glued: while the window is shorter than the content (the open
        // unfurl), the overflow extends below the window edge and is clipped,
        // instead of the content centering inside the short window.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
