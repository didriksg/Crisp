import AppKit
import SwiftUI
import CoreGraphics
import ApplicationServices
import Combine
import os.log

/// Borderless key-capable panel for the menu bar UI.
/// Owning the panel (instead of MenuBarExtra's window) removes the WindowServer
/// zoom-in materialization and gives us native-menu open behavior. All resize
/// animation lives in PanelCanvas (docs/panel-resize.md); the panel itself is
/// just the shell.
final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let log = Logger(subsystem: "com.crisp.app", category: "app")
    private var wakeObservers: [NSObjectProtocol] = []
    /// Coalesces the wake chain: a full system wake posts didWake and
    /// screensDidWake both, and one pass covers both.
    private var wakeTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    /// Debounces panel re-anchoring across the storm of screen-param changes a
    /// display connect/disconnect fires (see screenObserver).
    private var repositionWorkItem: DispatchWorkItem?
    private var clickMonitor: Any?
    private var clickInterceptor: Any?
    // Temporary probe: logs where every in-panel mouse-down lands in the view
    // tree, to corner the dead-click zones. Remove with the other probes.
    // The NSMenu currently tracking (a SwiftUI Menu / context menu), captured so an
    // outside-panel click can cancel it the way native menus dismiss on click-away.
    private var trackingMenu: NSMenu?

    // One-time migration of legacy `fd.*` UserDefaults keys into the `crisp.*`
    // namespace. Declared above `displayManager` on purpose: stored-property
    // initializers run in declaration order, and DisplayManager() reads persisted
    // keys during init (reapplySavedModeIfNeeded etc.), so this must complete first.
    private let _defaultsMigrated = AppDelegate.migrateLegacyDefaultsNamespace()

    let displayManager = DisplayManager()
    private lazy var controlServer = CrispControlServer(displayManager: displayManager)
    private var statusItem: NSStatusItem?
    /// Drives the menu-bar Keep Awake indicator (keep-awake indicator).
    private var keepAwakeCancellable: AnyCancellable?
    private var keepAwakeBadge: NSView?
    private var disconnectedCancellable: AnyCancellable?
    private var disconnectedBadge: NSView?
    private var panel: MenuPanel?
    /// The panel is NEVER ordered out once warmed: taking the backdrop surface
    /// off screen makes WindowServer replay its materialize bloom (the growing
    /// rectangle) on every reopen. Hidden = alpha 0 + click-through instead,
    /// so track shown-ness ourselves; isVisible stays true.
    private var isPanelShown = false
    /// Mirrors external state changes (Control Center, brightness keys, other
    /// apps) into the sliders while the panel is open. Started by showPanel,
    /// cancelled by closePanel: nothing polls while the panel is hidden;
    /// showPanel's click-time refresh covers state that drifted while closed.
    private var externalStatePollTask: Task<Void, Never>?

    /// Called after wake-from-sleep; wired in setupStartupBehavior.
    var onWake: (() -> Void)?

    /// One-time migration of legacy `fd.*` UserDefaults keys into the `crisp.*`
    /// namespace: copies each key to its `crisp.` counterpart (without clobbering an
    /// existing value) and drops the old one. Idempotent via a sentinel flag so
    /// existing installs keep their settings instead of resetting to defaults.
    @discardableResult
    static func migrateLegacyDefaultsNamespace() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "crisp.didMigrateLegacyDefaults") else { return false }
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("fd.") {
            let newKey = "crisp." + key.dropFirst(3)
            if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey) }
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: "crisp.didMigrateLegacyDefaults")
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate launch via an exclusive file lock. Unlike consulting
        // NSWorkspace (whose entries linger during teardown and race with fast
        // relaunches), flock is released by the kernel the moment a process dies.
        let lockPath = NSTemporaryDirectory() + "crisp.lock"
        let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if lockFD == -1 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            exit(0)
        }
        // The descriptor stays open for the app's lifetime to hold the lock.

        do {
            try controlServer.start()
        } catch {
            Self.log.error("Could not start local control socket: \(error.localizedDescription, privacy: .public)")
        }

        // Start intercepting brightness keys to route them to the display under the cursor,
        // but only if Accessibility is already granted. Creating the tap (tapCreate) is what
        // surfaces the OS prompt, so gating on trust keeps launch prompt-free; new users opt
        // in via the toggle in the Brightness Keys section, which arms it in context. (jv1b)
        if AXIsProcessTrusted() {
            BrightnessKeyService.shared.start()
        } else {
            // AXIsProcessTrusted() is unreliable at the exact launch instant, especially right
            // after an upgrade while macOS re-validates the replaced bundle: a user who already
            // granted access in the prior version would otherwise have the tap silently never arm
            // (the launch check reads false, and nothing re-arms it since the opt-in toggle is
            // hidden once trust settles true). Re-check a couple of times as trust settles and arm
            // if it has; start() is idempotent, and this is bounded so users who never granted
            // don't poll forever. (upgrade zombie)
            // Logged so a support capture shows the #57 case: System Settings lists
            // Crisp as allowed, but the grant belongs to a differently signed build.
            Self.log.notice("Accessibility not trusted at launch, key tap not started; re-checking at 1 s and 3 s")
            for delay in [1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if AXIsProcessTrusted() {
                        BrightnessKeyService.shared.start()
                    } else if delay == 3.0 {
                        Self.log.notice("Accessibility still not trusted after 3 s, brightness keys stay off until armed from the panel")
                    }
                }
            }
        }

        // Register all global shortcuts (preset shortcuts + Toggle HiDPI, issue #61).
        // Carbon hotkey: needs no Accessibility grant, so no gating like above.
        HotkeyService.shared.syncRegistrations()

        // Touch the singleton so auto-brightness polling starts at launch; otherwise
        // it only starts the first time the menu panel is opened (its only other ref).
        _ = AutoBrightnessService.shared

        // Re-establish Extra Brightness (EDR upscaling) for displays whose
        // toggle is persisted on. Deferred a beat so DisplayManager's initial
        // display list is populated.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            BrightnessBoostService.shared.reapplyAll()
        }

        // screensDidWake counts as much as didWake: displays that sleep on their
        // own (display idle timeout, Mac stays awake) come back with the transfer
        // table reset, and no didWake ever fires to restore it (issue #82).
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Delivered on `queue: .main`, so the main actor is current.
                MainActor.assumeIsolated { self?.onWake?() }
            })
        }

        setupStartupBehavior()
        setupStatusItem()
        DisconnectNoticeService.shared.start()

        // Re-anchor the open panel when screens change: switching the main
        // display re-origins global coordinates, which would otherwise leave
        // the panel floating at a stale position.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPanelShown, self.panel != nil else { return }
                // A display connect/disconnect fires a storm of these, and the
                // geometry is garbage mid-flight: a just-connected virtual display
                // can transiently read as NSScreen.main, spiking maxContentHeight
                // (the panel balloons past its cap) and the x/anchor clamp (the
                // panel offsets). Debounce so we re-anchor ONCE, after the storm
                // settles, instead of sampling the volatile mid-reconfig state.
                self.repositionWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isPanelShown, let p = self.panel else { return }
                    self.positionPanel(p, preferOrigin: true)
                }
                self.repositionWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }

        // A SwiftUI `Menu` (row ⋯ buttons, context menus) opens an AppKit menu in
        // its own window outside the panel frame. Suppress the panel's outside-click
        // / resign-key dismissal while any menu tracks, so clicking a menu item that
        // spilled past the panel edge doesn't close the panel out from under it.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] note in
            let menu = note.object as? NSMenu
            Task { @MainActor in
                PanelOpenGuard.isMenuTracking = true
                self?.trackingMenu = menu
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Outlast the outside-click monitor's own async main-actor hop
                // (which fired on the item's mouse-down) so it still sees tracking.
                try? await Task.sleep(nanoseconds: 150_000_000)
                PanelOpenGuard.isMenuTracking = false
                self?.trackingMenu = nil
            }
        }

        // Pre-warm the panel while hidden so the very first open, like every
        // reopen, appears at its final, settled size (fittingSize is only an
        // estimate; real layout can differ by a few points). Warm on the very
        // next runloop turn, not a 1s timer: a runloop turn is <16ms, but the
        // menu-bar icon isn't clickable until well after that, so the warm-up
        // (Liquid Glass materialize bloom + first layout) reliably finishes
        // hidden. On the 1s timer, a fast first click landed mid-warm and the
        // bloom + estimate reflow played on screen.
        DispatchQueue.main.async { [weak self] in
            self?.warmPanel()
        }

        // Start Sparkle's background update scheduler; a found update surfaces
        // as the panel's Update row (see UpdateService).
        _ = UpdateService.shared

    }

    /// One-shot re-sync of everything that can drift while the panel is closed
    /// (Night Shift/True Tone via Control Center, DDC brightness changed by the
    /// monitor's own buttons or another app). All reads run off the main
    /// thread; called at the click in showPanel.
    private func refreshExternalState() {
        CoreBrightnessService.shared.refresh()
        for display in displayManager.displays {
            Task { await BrightnessService.shared.refreshBrightness(for: display) }
        }
    }

    private func pollExternalState() {
        // The panel is never ordered out (hidden = alpha 0), so isVisible
        // alone is always true; alpha is the actual shown state.
        guard isPanelShown, let p = panel, p.alphaValue > 0 else { return }
        // Don't fight the user's own adjustments (or busy the DDC bus mid-drag).
        if let last = BrightnessService.shared.lastManualAdjustDate,
           Date().timeIntervalSince(last) < 3 { return }
        CoreBrightnessService.shared.refresh()
        let autoBrightnessOn = AutoBrightnessService.shared.isEnabled
        for display in visibleDisplays() {
            // Skip any display something else is actively driving (see the
            // original note in MenuBarView history, issue #12 follow-up).
            if display.isBuiltin || autoBrightnessOn { continue }
            Task { await BrightnessService.shared.refreshBrightness(for: display) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer.stop()
        for obs in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        BrightnessKeyService.shared.stop()
        // Drop EDR overlays and restore SDR on externals Crisp switched to HDR,
        // so no monitor is left bright with no boost and no DDC control.
        BrightnessBoostService.shared.prepareForTermination()
        // GammaService already handles CGDisplayRestoreColorSyncSettings via willTerminateNotification observer.
        // Unmirror before the virtual displays die, so no panel is left showing
        // a mirror of a display that just vanished.
        MirroredModeService.shared.teardownAll()
        VirtualDisplayService.shared.destroyAll()
    }

    // MARK: - Startup behavior (previously in CrispApp's task)

    private func setupStartupBehavior() {
        // Launching must never touch display state the user didn't ask for
        // (the inherited auto-arrange-external-above-builtin is gone).
        onWake = { [weak self] in
            guard let self, self.wakeTask == nil else { return }
            let dm = self.displayManager
            self.wakeTask = Task { @MainActor [weak self] in
                defer { self?.wakeTask = nil }
                // Give WindowServer 2 seconds to stabilize after wake before
                // touching display state.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // The refresh also re-disconnects any display macOS re-enabled on wake:
                // it runs reconcile, which puts a remembered disconnect back.
                dm.refreshDisplays()
                try? await Task.sleep(nanoseconds: 500_000_000)
                // WindowServer keeps settling for several seconds after wake: ICC
                // restore and link retraining can clobber a freshly applied transfer
                // table, which lost gamma adjustments until relaunch (issue #25).
                // Three passes with increasing delays so the last lands after the
                // churn; each is an idempotent no-op when state is already right.
                for delay: UInt64 in [0, 4_000_000_000, 8_000_000_000] {
                    try? await Task.sleep(nanoseconds: delay)
                    for display in dm.displays {
                        // Apply software brightness factor first so GammaService
                        // can read the up-to-date factor when it re-applies its formula.
                        BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                        GammaService.shared.reapplyIfNeeded(for: display)
                        // Re-apply any custom resolution that macOS may have reset on wake
                        ResolutionService.shared.reapplySavedModeIfNeeded(for: display.displayID)
                    }
                }
                // Re-establish EDR boost overlays (Metal drawables and HDR
                // mode may not survive sleep).
                BrightnessBoostService.shared.reapplyAll()
            }
        }
    }

    // MARK: - Status item + panel

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Not "display": that's the native Displays module icon, two identical
        // icons in the menu bar is confusing. Screen-with-sparkles keeps the vibe.
        let icon = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "Crisp")
        icon?.isTemplate = true
        item.button?.image = icon
        // Action stays wired for accessibility (AXPress); real clicks are
        // intercepted below and never reach the button.
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        // NSStatusBarButton's own click tracking force-clears its highlight at
        // mouse-up, which fights a persistent while-panel-open highlight
        // (flicker, or stuck off). Intercept clicks before the button sees
        // them: toggle directly, swallow the event so the button never tracks,
        // and showPanel/closePanel fully own the highlight. This also opens on
        // press with either button, like native menus. Cmd-clicks pass through
        // so the item can still be cmd-dragged.
        clickInterceptor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self,
                  let button = self.statusItem?.button,
                  event.window === button.window,
                  !event.modifierFlags.contains(.command) else { return event }
            self.togglePanel()
            return nil
        }
        statusItem = item

        // Overlay a small orange dot on the icon while Keep Awake is on, so it's visible at a
        // glance that sleep is being held. The base icon itself never changes. (keep-awake indicator)
        updateStatusIcon(active: KeepAwakeService.shared.isActive, animated: false)
        keepAwakeCancellable = KeepAwakeService.shared.$isActive
            .sink { [weak self] active in self?.updateStatusIcon(active: active, animated: true) }

        // And a second dot, opposite corner, while any display is disconnected. A disconnected
        // display shows no signal and does not appear in System Settings > Displays, so with
        // the disconnect now outliving a replug and a reboot, this is the only thing on screen
        // that says a display is being held off — and it is the thing a puzzled user clicks,
        // which is where the Reconnect row is.
        updateDisconnectedIcon(any: !PhysicalDisplayToggleService.shared.disconnected.isEmpty, animated: false)
        disconnectedCancellable = PhysicalDisplayToggleService.shared.$disconnected
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] any in self?.updateDisconnectedIcon(any: any, animated: true) }
    }

    /// Renders the status-bar icon for the given Keep Awake state. A hidden default
    /// (`crisp.debug.keepAwakeIconStyle` = "tint" | "badge") selects how "on" is shown, so
    /// the two can be compared live; default is tint. (keep-awake indicator)
    /// Fades a small orange dot in/out over the (unchanged) menu-bar icon to reflect Keep Awake.
    /// Only the dot animates; the base symbol stays put. (keep-awake indicator)
    private func updateStatusIcon(active: Bool, animated: Bool) {
        guard let button = statusItem?.button else { return }
        let badge = keepAwakeBadge ?? makeBadge(on: button, color: .systemOrange, trailing: true)
        keepAwakeBadge = badge
        fade(badge, to: active ? 1 : 0, animated: animated)
    }

    /// The same treatment for "a display is disconnected", in the opposite corner and a
    /// different colour so the two states can be told apart, and read at once.
    private func updateDisconnectedIcon(any: Bool, animated: Bool) {
        guard let button = statusItem?.button else { return }
        let badge = disconnectedBadge ?? makeBadge(on: button, color: .systemBlue, trailing: false)
        disconnectedBadge = badge
        fade(badge, to: any ? 1 : 0, animated: animated)
    }

    private func fade(_ badge: NSView, to target: CGFloat, animated: Bool) {
        guard animated else { badge.alphaValue = target; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            badge.animator().alphaValue = target
        }
    }

    /// A small dot pinned to one bottom corner of the icon, layer-backed so its alpha can
    /// animate. Starts hidden (alpha 0); the update methods above fade it in. Trailing/orange is
    /// Keep Awake (keep-awake indicator), leading/blue is "a display is disconnected".
    private func makeBadge(on button: NSStatusBarButton, color: NSColor, trailing: Bool) -> NSView {
        let d: CGFloat = 6
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = d / 2
        dot.alphaValue = 0
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)
        let side = trailing
            ? dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1)
            : dot.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 1)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: d),
            dot.heightAnchor.constraint(equalToConstant: d),
            side,
            dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -2)
        ])
        return dot
    }

    private var isWarmed = false
    /// False until the panel has been shown once this launch. The first show fades
    /// in to mask one-time on-screen costs; later shows are instant.
    private var hasShownOnce = false

    /// Split-canvas resize engine and the shared section state (docs/panel-resize.md).
    private let canvas = PanelCanvas()
    private let sectionState = PanelSectionState()
    private var canvasCancellables = Set<AnyCancellable>()
    /// Identity of the block list currently built; rebuilt when it changes
    /// (displays connect/disconnect/reorder).
    private var blocksSignature = ""

    private func warmPanel() {
        let p = panel ?? makePanel()
        panel = p
        guard !isWarmed else { return }
        isWarmed = true
        // Static-window architecture: the window never resizes while an
        // animation is in flight (a per-frame shadowed-window resize costs
        // 5-9ms in the WindowServer, the measured root cause of every
        // cadence failure). The visible panel is the `shell` inside a larger
        // transparent window; the spring animates the shell as pure layer
        // work, and the shadow is a CALayer twin that resizes in the same
        // atomic commit.
        let windowW = canvas.width + canvas.sideMargin * 2
        let root = PanelRootView(frame: NSRect(x: 0, y: 0, width: windowW, height: 480))
        let shadow = NSView(frame: .zero)
        let shadowLayer = CALayer()
        shadowLayer.masksToBounds = false
        // The twin sits OUTSET one device pixel from the shell (PanelCanvas
        // computes it), so this black stroke falls just OUTSIDE the glass,
        // where the WindowServer rim strokes its 1px hairline.
        // Width 2, not 1: the knockout mask trims the band back to a 1px
        // ring on straight edges, but at corners the wider stroke keeps the
        // arc at full darkness where a 1px border is AA-diluted. Alpha is
        // appearance-dependent and set per flight in PanelCanvas (measured:
        // ~0.29 light mode, ~0.85 dark mode).
        shadowLayer.borderWidth = 2
        shadowLayer.borderColor = NSColor.black.withAlphaComponent(0.29).cgColor
        shadowLayer.cornerRadius = 17
        // Knockout mask: an empty layer does not cover its own shadow, so
        // the blurred silhouette is visible through the shape interior too,
        // and the glass backdrop would sample it (the whole panel reads
        // darker in flight). Even-odd keeps only the ring outside the shell.
        let knockout = CAShapeLayer()
        knockout.fillRule = .evenOdd
        shadowLayer.mask = knockout
        shadow.layer = shadowLayer
        shadow.wantsLayer = true
        // The shadow MUST be set through the view API: AppKit syncs the
        // view's `shadow` property onto the layer on every display pass, so
        // raw layer shadow properties get clobbered (observed: shadowOpacity
        // reset to 0 while radius and path survived). The explicit
        // shadowPath (layoutNow) still keeps per-tick resizes cheap.
        // Numbers are a pixel-measured clone of the WindowServer shadow this
        // panel wears at rest (bottom: ~16% edge darkening over ~17px, sides
        // ~11%), so the rest<->flight swap is invisible.
        let menuShadow = NSShadow()
        menuShadow.shadowColor = NSColor.black.withAlphaComponent(0.21)
        menuShadow.shadowBlurRadius = 8.5
        menuShadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadow = menuShadow
        root.addSubview(shadow)

        // Blocks live INSIDE a plain container, never as the window
        // contentView: as contentView, NSHostingView installs its own
        // window-sizing machinery that fights manual resizes.
        let shell = NSView(frame: NSRect(x: canvas.sideMargin, y: 0, width: canvas.width, height: 400))
        // Clip the whole container to the panel shape: the glass view's
        // square bounds otherwise peek past the rounded corners (double edge).
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 16
        shell.layer?.masksToBounds = true
        // The WindowServer shadow strokes a two-line rim around the window
        // shape (measured: ~0.38 black just outside the boundary, ~0.32
        // white on the first row inside; light mode shows the black line,
        // dark mode the white one), and both vanish with hasShadow off.
        // Flights redraw the white line as this border (width toggled in
        // PanelCanvas); the black line lives on the outset shadow twin.
        shell.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        // The menu backdrop: macOS 26 Liquid Glass, the material Control
        // Center panels actually use (no NSVisualEffectView grade matches
        // it). Its materialize bloom plays only when the view first comes on
        // screen, which happens once during hidden warm-up; the panel never
        // orders out afterwards.
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: shell.bounds)
            glass.cornerRadius = 16
            backdrop = glass
        } else {
            // Pre-Tahoe: .popover is the translucent grade native menus and
            // Control Center panels show on macOS 15.
            let material = NSVisualEffectView(frame: shell.bounds)
            material.material = .popover
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 16
            material.layer?.masksToBounds = true
            backdrop = material
        }
        // Oversized fixed canvas glued to the shell top, clipped by the
        // shell's rounded mask: resizing the shell then only MOVES the glass
        // layer (autoresizing it with the shell cost ~3ms per tick in its
        // internal layout).
        let backdropHeight: CGFloat = 2200
        backdrop.frame = NSRect(x: 0, y: shell.bounds.height - backdropHeight,
                                width: canvas.width, height: backdropHeight)
        backdrop.autoresizingMask = [.minYMargin]
        shell.addSubview(backdrop)
        root.addSubview(shell)
        root.shell = shell
        root.onOutsideClick = { [weak self] in self?.closePanel() }

        p.setFrame(NSRect(x: 0, y: -4000, width: windowW, height: 480), display: false)
        p.contentView = root
        canvas.install(shell: shell, shadow: shadow, panel: p)
        canvas.shadowMask = knockout
        canvas.isShown = { [weak self] in self?.isPanelShown ?? false }
        // Off-screen anchor for the warm-up; openPanel sets the real one.
        canvas.setAnchor(topY: -4000, x: 0)
        rebuildBlocksIfNeeded(force: true)
        wireCanvasSubscriptions()

        // Bring the surface on screen invisibly so the backdrop's one-time
        // materialize animation plays now, while nobody can see it, and every
        // block paints once (no first reveal is ever a first paint).
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        p.orderFrontRegardless()
        canvas.prePaint()
        // Warm-up done, panel hidden: no vsync ticks until the first open.
        canvas.parkSpring()
    }

    /// Displays that get their own section, in panel order (screen the panel
    /// was opened on first, then builtin, then physical arrangement).
    private func visibleDisplays() -> [DisplayInfo] {
        let active = displayManager.activePanelDisplayID
        return displayManager.displays
            .filter { !VirtualDisplayService.shared.isVirtualDisplay($0.displayID) }
            .sorted {
                if ($0.displayID == active) != ($1.displayID == active) { return $0.displayID == active }
                if $0.isBuiltin != $1.isBuiltin { return $0.isBuiltin }
                let a = CGDisplayBounds($0.displayID), b = CGDisplayBounds($1.displayID)
                return a.minY != b.minY ? a.minY < b.minY : a.minX < b.minX
            }
    }

    /// Builds the block list when its identity changed (display set/order).
    /// Rebuild is a snap, not an animation; it only happens on discontinuous
    /// events (connect/disconnect, or a different screen on open).
    private func rebuildBlocksIfNeeded(force: Bool = false) {
        let vis = visibleDisplays()
        let signature = vis.map(\.displayUUID).joined(separator: "|")
        guard force || signature != blocksSignature else { return }
        blocksSignature = signature

        let dm = displayManager
        let state = sectionState
        let settings = SettingsService.shared
        func host<V: View>(_ id: String, @ViewBuilder _ content: () -> V) -> NSView {
            let h = CountedHostingView(rootView: AnyView(
                BlockHost(onHeight: { [weak self] h in self?.canvas.contentChanged(id, height: h) }) {
                    content()
                }
                .environmentObject(dm)
            ))
            // Blocks near the window's top/bottom edge otherwise get a phantom
            // safe-area inset: content shifts inside the host while the AppKit
            // frame stays put, so clicks land ~12pt off (dead bands at the
            // edges) and the inset flips with window height (spurious height
            // reports, visible as jumps).
            h.safeAreaRegions = []
            return h
        }
        func block<V: View>(_ id: String, isOpen: @escaping () -> Bool = { true },
                            @ViewBuilder _ content: () -> V) -> PanelBlock {
            PanelBlock(id: id, host: host(id, content), isOpen: isOpen)
        }

        var blocks: [PanelBlock] = []
        for (index, display) in vis.enumerated() {
            let id = display.displayID
            let uuid = display.displayUUID
            let dhead = block("dhead-\(uuid)") {
                DisplayHeaderBlock(display: display, isFirst: index == 0, state: state)
            }
            dhead.liveInFlight = true   // display row chevron
            blocks.append(dhead)
            // The expanded detail, split so every dropdown is its own block:
            // the canvas animates each reveal as a clip over content that
            // rendered once at natural height, so nothing re-renders per frame
            // (the 120Hz fix for the nested dropdowns; docs/panel-resize.md).
            // Controllers hold the state the sibling blocks share; the block
            // hosts retain them. Every detail block carries the shaded band
            // the one-piece detail view had, painted on the clip layer
            // (banded) so reveal fades dim only the content, never the band.
            let modeC = DisplayModeController(display: display, displayManager: dm)
            let profC = DisplayProfileController(display: display)
            let detailOpen = { state.expandedDisplayIDs.contains(id) }
            func detail<V: View>(_ sub: String, isOpen: @escaping () -> Bool,
                                 live: Bool = false,
                                 @ViewBuilder _ content: () -> V) -> PanelBlock {
                let b = block("\(sub)-\(uuid)", isOpen: isOpen) {
                    content()
                        .padding(.leading, 4)
                }
                b.banded = true
                b.liveInFlight = live
                return b
            }
            blocks.append(detail("dres-head", isOpen: detailOpen, live: true) {
                ResolutionHeadBlock(controller: modeC, state: state)
            })
            blocks.append(detail("dres-body", isOpen: {
                detailOpen() && state.resolutionOpenIDs.contains(id)
            }) {
                ResolutionSliderBlock(controller: modeC, state: state)
            })
            blocks.append(detail("dres-all", isOpen: {
                detailOpen() && state.resolutionOpenIDs.contains(id)
                    && state.allResolutionsOpenIDs.contains(id)
            }) {
                ResolutionFullListBlock(controller: modeC)
            })
            blocks.append(detail("dref-head", isOpen: detailOpen, live: true) {
                RefreshHeadBlock(controller: modeC, state: state)
            })
            blocks.append(detail("dref-body", isOpen: {
                detailOpen() && state.refreshOpenIDs.contains(id)
            }) {
                RefreshListBlock(controller: modeC)
            })
            blocks.append(detail("dmode-tail", isOpen: detailOpen) {
                ModeTailBlock(controller: modeC)
            })
            blocks.append(detail("dprof-head", isOpen: detailOpen, live: true) {
                ProfileHeadBlock(controller: profC, state: state)
            })
            blocks.append(detail("dprof-body", isOpen: {
                detailOpen() && state.profileOpenIDs.contains(id)
            }) {
                ProfileBodyBlock(controller: profC)
            })
            blocks.append(detail("dimg-head", isOpen: detailOpen, live: true) {
                ImageHeadBlock(display: display, state: state)
            })
            blocks.append(detail("dimg-body", isOpen: {
                detailOpen() && state.imageOpenIDs.contains(id)
            }) {
                ImageBodyBlock(display: display, state: state)
            })
            blocks.append(detail("dtail", isOpen: detailOpen) {
                DetailTailBlock(display: display)
            })
        }
        blocks.append(block("reconnect") { ReconnectDisplaysSection() })
        let visCount = vis.count
        blocks.append(block("combined",
                            isOpen: { settings.showCombinedBrightness && visCount > 1 }) {
            VStack(spacing: 0) {
                SectionDivider()
                CombinedBrightnessView(displays: vis)
            }
        })
        if CoreBrightnessService.shared.darkModeAvailable
            || CoreBrightnessService.shared.nightShiftAvailable
            || CoreBrightnessService.shared.trueToneAvailable {
            blocks.append(block("effects") { ScreenEffectsView() })
        }
        blocks.append(block("presets") {
            VStack(alignment: .leading, spacing: 0) {
                SectionDivider()
                SectionHeader(title: "Presets")
                PresetListView()
            }
        })
        let toolshead = block("toolshead") {
            VStack(alignment: .leading, spacing: 0) {
                SectionDivider()
                ExpandableRowStateful(icon: "wrench.and.screwdriver.fill", iconActive: false,
                                      label: "Tools", state: state, key: \.showTools)
            }
        }
        toolshead.liveInFlight = true
        blocks.append(toolshead)
        let toolsA = block("toolsA", isOpen: { state.showTools }) {
            VStack(alignment: .leading, spacing: 0) {
                if !KeepAwakeService.isDisabledByPolicy {
                    KeepAwakeRow()
                }
                ExpandableRowStateful(icon: "display.2", iconActive: false,
                                      label: "Virtual Displays", state: state, key: \.showVirtualDisplays)
            }
            .padding(.leading, 8)
        }
        toolsA.liveInFlight = true   // Virtual Displays chevron
        blocks.append(toolsA)
        blocks.append(block("vdrows", isOpen: { state.showTools && state.showVirtualDisplays }) {
            VirtualDisplayView()
                .padding(.leading, 16)
        })
        let toolsB = block("toolsB", isOpen: { [weak dm] in
            state.showTools && (dm?.displays.count ?? 0) > 1
        }) {
            ExpandableRowStateful(icon: "rectangle.3.offgrid", iconActive: false,
                                  label: "Arrange Displays", state: state, key: \.showArrangement)
                .padding(.leading, 8)
        }
        toolsB.liveInFlight = true
        blocks.append(toolsB)
        blocks.append(block("arrangerows", isOpen: { [weak dm] in
            state.showTools && state.showArrangement && (dm?.displays.count ?? 0) > 1
        }) {
            ArrangementView()
                .padding(.leading, 8)
        })
        let settingshead = block("settingshead") {
            ExpandableRowStateful(icon: "gearshape.fill", iconActive: false,
                                  label: "Settings", state: state, key: \.showSettings)
        }
        settingshead.liveInFlight = true
        blocks.append(settingshead)
        blocks.append(block("settingsrows", isOpen: { state.showSettings }) {
            SettingsView()
                .padding(.leading, 8)
        })
        blocks.append(block("update") { UpdateBlockView() })

        let footer = block("footer") { PanelFooterBlock() }
        canvas.setBlocks(blocks, footer: footer)
        canvas.snapToTargets()
    }

    /// Everything that must drive the canvas: section state, the combined
    /// brightness preference, display list changes, and the deferred
    /// resolution-section expand after a soft-reconnect.
    private func wireCanvasSubscriptions() {
        sectionState.objectWillChange
            .sink { [weak self] _ in self?.canvas.requestApply() }
            .store(in: &canvasCancellables)
        // Light<->dark switched while the panel is open: re-tint the rim/shadow
        // live (Control Center / System Settings post this app-wide). The async
        // hop lets NSApp.effectiveAppearance settle to the new value first.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.canvas.refreshAppearance() }
        }
        SettingsService.shared.$showCombinedBrightness
            .dropFirst()
            .sink { [weak self] _ in self?.canvas.requestApply() }
            .store(in: &canvasCancellables)
        displayManager.$displays
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newDisplays in
                guard let self else { return }
                let validIDs = Set(newDisplays.map { $0.displayID })
                self.sectionState.retainDisplays(validIDs)
                self.rebuildBlocksIfNeeded()
                self.canvas.requestApply()
            }
            .store(in: &canvasCancellables)
        displayManager.$pendingResolutionExpandUUID
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uuid in
                // A smooth-scaling reconnect rebuilt this display's row collapsed;
                // re-expand its detail and reopen its Resolution section, so the
                // user lands back where they were.
                guard let self,
                      let d = self.displayManager.displays.first(where: { $0.displayUUID == uuid })
                else { return }
                self.sectionState.expandedDisplayIDs.insert(d.displayID)
                self.sectionState.resolutionOpenIDs.insert(d.displayID)
                // Consume the request (the compactMap above ignores the nil).
                DispatchQueue.main.async { self.displayManager.pendingResolutionExpandUUID = nil }
            }
            .store(in: &canvasCancellables)
        NotificationCenter.default.publisher(for: .crispPanelDidClose)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sectionState.collapseAll() }
            .store(in: &canvasCancellables)
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
    /// Display the open panel was summoned on, by stable UUID (displayIDs are
    /// reassigned across a soft-reconnect). When that display blanks, the status
    /// item's window migrates to a surviving display and the post-storm reposition
    /// would drag the panel there for good; `preferOrigin` re-anchors to this
    /// display once it's back online.
    private var panelOriginDisplayUUID: String?

    private func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String
    }

    private func positionPanel(_ p: MenuPanel, preferOrigin: Bool = false) {
        guard let btnWindow = statusItem?.button?.window else { return }
        let btnFrame = btnWindow.frame
        let btnScreen = btnWindow.screen ?? NSScreen.main
        var screen = btnScreen
        var anchorMidX = btnFrame.midX
        var topY = btnFrame.minY - 1
        // After a reconnect storm, prefer the display the panel was opened on if
        // it's online again. The menu bar mirrors across displays, so mirror the
        // status item's offset from the right edge onto the origin screen.
        if preferOrigin,
           let uuid = panelOriginDisplayUUID,
           let bs = btnScreen,
           let origin = NSScreen.screens.first(where: { displayUUID(for: $0.displayID) == uuid }),
           origin != bs {
            screen = origin
            anchorMidX = origin.frame.maxX - (bs.frame.maxX - btnFrame.midX)
            topY = origin.visibleFrame.maxY - 1
        }
        displayManager.activePanelDisplayID = screen?.displayID
        let width = canvas.width
        var x = anchorMidX - width / 2
        if let vis = screen?.visibleFrame {
            x = min(max(x, vis.minX + 8), vis.maxX - width - 8)
        }
        if let vis = screen?.visibleFrame {
            // Cap like the native Wi-Fi panel: grow to ~80% of the drop below
            // the status item, then scroll, leaving real breathing room at
            // the screen bottom instead of touching it.
            PanelMetrics.maxContentHeight = max(400, (topY - vis.minY) * 0.8)
        }
        canvas.setAnchor(topY: topY, x: x)
        canvas.snapToTargets()
    }

    private func showPanel() {
        // Content stays alive across opens (warm is a no-op after the first
        // call) so nothing mounts or animates in at open time; per-open state
        // refresh happens below instead.
        warmPanel()
        guard let p = panel else { return }

        // Kick the refresh of everything that can drift while the panel is
        // closed NOW, at the click: the reads run off the main thread and land
        // during the fade-in, so the sliders are correct by the time the panel
        // is readable instead of visibly jumping shortly after it opened.
        refreshExternalState()

        // Native menus appear at full size with all content visible at once;
        // only size changes AFTER opening animate.
        positionPanel(p)
        canvas.retargetLinkIfNeeded()
        canvas.wakeSpring()
        // The display order can differ per open (panel-screen-first sort);
        // rebuild happens hidden, before the fade.
        rebuildBlocksIfNeeded()
        // Remember where this open happened (fresh each open; the menu bar the
        // user clicked is the anchor, not wherever a previous open ended up).
        panelOriginDisplayUUID = displayManager.activePanelDisplayID.flatMap { displayUUID(for: $0) }

        // Re-apply the appearance-tied rim/shadow before the panel becomes
        // visible: the colors are only otherwise refreshed on a flight, so the
        // first open (launch-time appearance) or an open after a light<->dark
        // switch would show the other mode's rim until an expansion fixed it.
        canvas.refreshAppearance()

        p.ignoresMouseEvents = false
        // First open only: fade in briefly so the panel's one-time on-screen costs
        // (Liquid Glass materialize bloom, first backdrop sample, first rasterization)
        // play under the fade instead of glitching in visibly, the way native menus'
        // appearance animation masks the same cost. The offscreen/alpha-0 warm-up can't
        // pre-play them (glass only materializes when genuinely on screen). The panel
        // sits at alpha 0 (warm-up / last close), so this is a clean 0 -> 1; every later
        // open stays instant (duration 0), replacing any in-flight close fade.
        let appearDuration: TimeInterval = hasShownOnce ? 0 : 0.12
        hasShownOnce = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = appearDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
        p.orderFrontRegardless()
        p.makeKey()
        isPanelShown = true
        // Native items keep the menu bar button highlighted while their panel
        // is open. Safe to set synchronously: the click never starts the
        // button's own tracking (the interceptor swallowed it), so nothing
        // resets this behind our back.
        statusItem?.button?.highlight(true)

        // Re-sync views that mirror live external state (e.g. the system auto-brightness
        // toggle) on every open; the panel content mounts once, so their .onAppear
        // won't re-fire here.
        NotificationCenter.default.post(name: .crispPanelDidOpen, object: nil)

        // Re-probe DDC volume for externals that haven't answered yet: the
        // connect-time probe (+3s retry) can land inside the post-link-training
        // garbage window, and nothing else retries. Once per open is bounded
        // I2C traffic, and a success is remembered so this stops firing for
        // that display.
        for display in visibleDisplays() where !display.isBuiltin && !display.volumeSupported {
            VolumeService.shared.refreshVolume(for: display)
        }

        PanelOpenGuard.openedAt = Date()

        // Mirror changes made elsewhere while the panel stays open (the
        // click-time refresh above covered the open itself). Cancelled on
        // close: a hidden panel needs no heartbeat.
        if externalStatePollTask == nil {
            externalStatePollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.pollExternalState()
                }
            }
        }

        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.panel != nil else { return }
                    // Don't dismiss while our own admin auth dialog is up: those
                    // clicks land in SecurityAgent (outside the panel). Same for a
                    // tracking menu whose items spill outside the panel frame, or an
                    // in-panel confirmation alert awaiting a choice.
                    // A menu is tracking: an outside-panel click should dismiss the
                    // MENU the way native menus do, but keep the panel open. Clicks
                    // on the menu itself go to our own menu window and never reach
                    // this global monitor, so selecting an item (even one spilled
                    // past the panel edge) is unaffected.
                    // The window frame includes transparent shadow margins;
                    // the VISIBLE panel is the shell (canvas).
                    let visible = self.canvas.visibleScreenFrame()
                    if PanelOpenGuard.isMenuTracking {
                        if !visible.contains(NSEvent.mouseLocation) {
                            self.trackingMenu?.cancelTracking()
                        }
                        return
                    }
                    if PanelOpenGuard.suppressAutoDismiss
                        || PanelOpenGuard.isConfirmationActive { return }
                    // Global monitors normally fire only for clicks landing in
                    // OTHER apps (= outside the panel). But during the dark
                    // mode crossfade the system's snapshot overlay intercepts
                    // every click, so an inside click arrives here too; close
                    // only when the cursor is genuinely outside the panel.
                    if visible.contains(NSEvent.mouseLocation) { return }
                    self.closePanel()
                }
            }
        }
    }

    private func closePanel() {
        guard let p = panel, isPanelShown else { return }
        isPanelShown = false
        statusItem?.button?.highlight(false)
        canvas.parkSpring()
        externalStatePollTask?.cancel()
        externalStatePollTask = nil
        // Hide with a quick fade, like native menus; never order out (see
        // isPanelShown comment). Click-through is immediate.
        p.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Hidden now: tell the content to collapse its tool/nav sections so the
            // next open is fresh. Skip if the panel was reopened during the fade.
            // Animation completion runs on the main thread.
            MainActor.assumeIsolated {
                guard let self, !self.isPanelShown else { return }
                NotificationCenter.default.post(name: .crispPanelDidClose, object: nil)
            }
        })
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
        // The shadow is a CALayer twin of the shell (PanelCanvas), not the
        // WindowServer's: the server recomputes a transparent window's shadow
        // from its alpha shape on EVERY setFrame (~5ms, measured), which is
        // what made animated resizes judder.
        p.hasShadow = false
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        // Must be able to join the Space of a full-screen app: from its revealed
        // menu bar the click registers (icon highlights) but the panel otherwise
        // lands invisibly on the desktop Space.
        p.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        p.onCancel = { [weak self] in self?.closePanel() }
        return p
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? MenuPanel) === panel {
            // Don't dismiss while our own admin auth dialog is up: it steals key
            // as it appears (the HiDPI override install prompt). Same for a
            // tracking menu or an in-panel confirmation alert, which take key.
            if PanelOpenGuard.suppressAutoDismiss || PanelOpenGuard.isMenuTracking
                || PanelOpenGuard.isConfirmationActive { return }
            // A soft-reconnect just settled: focus steals in its wake are system
            // noise, not the user clicking away (those still close via the global
            // click monitor, which ignores this grace).
            if Date() < PanelOpenGuard.resignKeyGraceUntil { return }
            // Same overlay caveat as the click monitor: during the crossfade
            // the snapshot window can steal key while the user is clicking
            // INSIDE the panel; don't treat that as clicking away. The window
            // frame includes shadow margins, so test the visible shell.
            if canvas.visibleScreenFrame().contains(NSEvent.mouseLocation) { return }
            closePanel()
        }
    }
}
