import AppKit
import SwiftUI
import CoreGraphics
import ApplicationServices
import Combine
import os.log

/// Borderless key-capable panel for the menu bar UI (see CrispApp.swift for why
/// AppDelegate owns it instead of MenuBarExtra). All resize animation lives in
/// PanelCanvas (docs/panel-resize.md); the panel itself is just the shell.
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
    /// Set by didWake only, never by screensDidWake: the True Tone re-assert below is
    /// for a full system wake, where the external is still training its link when
    /// macOS computes True Tone (issue #131); a display sleep never has that.
    private var fullWakePending = false
    private var screenObserver: NSObjectProtocol?
    /// Debounces panel re-anchoring across the storm of screen-param changes a
    /// display connect/disconnect fires (see screenObserver).
    private var repositionWorkItem: DispatchWorkItem?
    private var clickMonitor: Any?
    private var clickInterceptor: Any?
    private var statusItemCatcher: StatusItemCatcher?
    // The NSMenu currently tracking (a SwiftUI Menu / context menu), captured so an
    // outside-panel click can cancel it the way native menus dismiss on click-away.
    private var trackingMenu: NSMenu?

    // Declared above `displayManager` on purpose: stored-property initializers run
    // in declaration order, and DisplayManager() reads persisted keys during init
    // (reapplySavedModeIfNeeded etc.), so this migration must complete first.
    private let _defaultsMigrated = AppDelegate.migrateLegacyDefaultsNamespace()

    let displayManager = DisplayManager()
    private lazy var controlServer = CrispControlServer(displayManager: displayManager)
    private var statusItem: NSStatusItem?
    /// Whether the OSD banner is asking for the menu bar item to be lit. The
    /// open panel asks for the same light, so both are read together.
    private var bannerLightsStatusItem = false
    /// Drives the menu-bar Keep Awake indicator (keep-awake indicator).
    private var keepAwakeCancellable: AnyCancellable?
    private var keepAwakeBadge: NSView?
    private var panel: MenuPanel?
    /// The panel is NEVER ordered out once warmed: taking the backdrop surface
    /// off screen replays WindowServer's materialize bloom. Hidden = alpha 0 +
    /// click-through instead; isVisible stays true, so track shown-ness ourselves.
    private var isPanelShown = false
    /// Mirrors external state changes (Control Center, brightness keys, other
    /// apps) into the sliders while the panel is open. Started by showPanel,
    /// cancelled by closePanel.
    private var externalStatePollTask: Task<Void, Never>?

    /// Called after wake-from-sleep; wired in setupStartupBehavior.
    var onWake: (() -> Void)?

    /// One-time migration of legacy `fd.*` UserDefaults keys into the `crisp.*`
    /// namespace, idempotent via a sentinel flag so existing installs keep their
    /// settings instead of resetting to defaults.
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

        // Route brightness keys to the display under the cursor, but only if
        // Accessibility is already granted: creating the tap surfaces the OS
        // prompt. New users opt in via the Brightness Keys toggle. (jv1b)
        if AXIsProcessTrusted() {
            BrightnessKeyService.shared.start()
        } else {
            // AXIsProcessTrusted() can read false right after launch even when
            // access is already granted (upgrade zombie, #57). Re-check at 1 s
            // and 3 s and arm if true; start() is idempotent.
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
        // Built here rather than at first use so its init runs on every launch: it
        // drops the orphaned saved-resolution key.
        _ = ResolutionService.shared

        // Re-establish Extra Brightness (EDR upscaling) for displays whose
        // toggle is persisted on. Deferred a beat so DisplayManager's initial
        // display list is populated.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            BrightnessBoostService.shared.reapplyAll()
        }

        // Restore a color mode explicitly chosen in Crisp on a fresh launch too.
        // Delay one second to let the initial display and WindowServer mode lists settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.displayManager.refreshDisplays()
            var restored = false
            for display in self.displayManager.displays {
                if DisplayColorModeService.shared.restoreSavedModeIfNeeded(for: display) {
                    restored = true
                }
            }
            if restored {
                NotificationCenter.default.post(name: .crispDisplayColorModeNeedsRefresh, object: nil)
            }
        }

        // Record every display's mode as the screens go down, so the wake passes
        // below can put back what macOS moved and nothing else. Both notifications:
        // a display idle timeout posts screensDidSleep with no system sleep at all.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                // Delivered on `queue: .main`, so the main actor is current.
                MainActor.assumeIsolated { ResolutionService.shared.snapshotModesForSleep() }
            })
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
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didWakeNotification { self?.fullWakePending = true }
                    self?.onWake?()
                }
            })
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
                guard let self, self.isPanelShown, self.panel != nil else { return }
                // A display connect/disconnect fires a storm of these with garbage
                // mid-flight geometry (a virtual display can transiently read as
                // NSScreen.main). Debounce to re-anchor ONCE, after the storm settles.
                self.repositionWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isPanelShown, let p = self.panel else { return }
                    self.positionPanel(p, preferOrigin: true)
                }
                self.repositionWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }

        // A SwiftUI `Menu` opens an AppKit menu in its own window outside the panel
        // frame. Suppress the panel's outside-click/resign-key dismissal while any
        // menu tracks, so a spilled-over click doesn't close the panel underneath it.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Posted on the main queue, and a menu never leaves the main thread. The
            // compiler cannot see that through the notification, so it reads the hop
            // below as a race without this.
            nonisolated(unsafe) let menu = note.object as? NSMenu
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

        // Pre-warm the panel while hidden so the first open, like every reopen,
        // appears at its final settled size. Warm on the next runloop turn (<16ms,
        // before the icon is clickable), not a timer, so a click can't land mid-warm.
        DispatchQueue.main.async { [weak self] in
            self?.warmPanel()
        }

        // Start Sparkle's background update scheduler; a found update surfaces
        // as the panel's Update row (see UpdateService).
        _ = UpdateService.shared

    }

    /// One-shot re-sync of everything that can drift while the panel is closed
    /// (Night Shift/True Tone, DDC brightness changed externally). Reads run off
    /// the main thread; called at the click in showPanel.
    private func refreshExternalState() {
        CoreBrightnessService.shared.refresh()
        for display in displayManager.displays {
            Task { await BrightnessService.shared.refreshBrightness(for: display) }
        }
    }

    private func pollExternalState() {
        // isVisible is always true (see isPanelShown); alphaValue is the real shown state.
        guard isPanelShown, let p = panel, p.alphaValue > 0 else { return }
        // Don't fight the user's own adjustments (or busy the DDC bus mid-drag).
        if let last = BrightnessService.shared.lastManualAdjustDate,
           Date().timeIntervalSince(last) < 3 { return }
        CoreBrightnessService.shared.refresh()
        let autoBrightnessOn = AutoBrightnessService.shared.isEnabled
        for display in visibleDisplays() {
            // Skip any display something else is actively driving (issue #12 follow-up).
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

    // MARK: - Startup behavior

    private func setupStartupBehavior() {
        // Launch must never touch display state the user didn't ask for: no
        // automatic arrange-external-above-builtin.
        onWake = { [weak self] in
            guard let self, self.wakeTask == nil else { return }
            let dm = self.displayManager
            self.wakeTask = Task { @MainActor [weak self] in
                defer {
                    self?.wakeTask = nil
                    self?.fullWakePending = false
                }
                // Give WindowServer 2 seconds to stabilize after wake before
                // touching display state.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // The refresh also re-disconnects any display macOS re-enabled on wake:
                // it runs reconcile, which puts a remembered disconnect back.
                dm.refreshDisplays()
                try? await Task.sleep(nanoseconds: 500_000_000)
                // WindowServer keeps settling for seconds after wake: ICC restore and
                // link retraining can clobber a freshly applied transfer table (#25).
                // Three passes with increasing delays; services reapply state as needed.
                var restoredColorModeUUIDs: Set<String> = []
                for delay: UInt64 in [0, 4_000_000_000, 8_000_000_000] {
                    try? await Task.sleep(nanoseconds: delay)
                    var colorModeChangeRequested = false
                    for display in dm.displays {
                        // Apply software brightness factor first so GammaService
                        // can read the up-to-date factor when it re-applies its formula.
                        BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                        GammaService.shared.reapplyIfNeeded(for: display)
                        // Re-apply any custom resolution that macOS may have reset on wake
                        let resolutionRestored = await ResolutionService.shared.restoreModeAfterWakeIfNeeded(
                            for: display.displayID
                        )
                        if resolutionRestored == true {
                            // Let the new timing appear in WindowServer before reading
                            // its compatible color formats.
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }
                        // Skip color after a failed or timed-out resolution request;
                        // try again on the next wake pass.
                        if resolutionRestored != false,
                           !restoredColorModeUUIDs.contains(display.displayUUID),
                           DisplayColorModeService.shared.restoreSavedModeIfNeeded(for: display) {
                            restoredColorModeUUIDs.insert(display.displayUUID)
                            colorModeChangeRequested = true
                        }
                    }
                    if colorModeChangeRequested { try? await Task.sleep(nanoseconds: 250_000_000) }
                    NotificationCenter.default.post(name: .crispDisplayColorModeNeedsRefresh, object: nil)
                    // Once an external is back after a full wake, toggle True Tone so macOS
                    // recomputes it with that display present (issue #131). Once per wake,
                    // at the first pass that lists an external.
                    if self?.fullWakePending == true, dm.displays.contains(where: { !$0.isBuiltin }) {
                        self?.fullWakePending = false
                        if CoreBrightnessService.shared.reassertTrueTone() {
                            Self.log.notice("True Tone re-asserted after wake with an external display back (issue #131)")
                        }
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
        // macOS 27 sizes a menu bar item around its image, and its lit pill
        // follows that width. A square item is 11 pt narrower than a native one
        // carrying the same symbol, which a fixed length cannot follow.
        let length = SystemLook.isMacOS27OrLater ? NSStatusItem.variableLength : NSStatusItem.squareLength
        let item = NSStatusBar.system.statusItem(withLength: length)
        // Not "display": that's the native Displays module icon, two identical
        // icons in the menu bar is confusing. Screen-with-sparkles keeps the vibe.
        let icon = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "Crisp")
        icon?.isTemplate = true
        item.button?.image = icon
        // Action stays wired for accessibility (AXPress); real clicks are
        // intercepted below and never reach the button.
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        // NSStatusBarButton's own click tracking fights a persistent while-panel-open
        // highlight: intercept clicks before the button sees them and swallow the
        // event, so showPanel/closePanel own the highlight. Cmd-clicks pass through.
        clickInterceptor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self,
                  let button = self.statusItem?.button,
                  event.window === button.window,
                  !event.modifierFlags.contains(.command) else { return event }
            self.togglePanel()
            return nil
        }
        statusItem = item
        // Both need the button laid out first (it has no width until then):
        // StatusItemHighlight widens the clipping window before anything draws, and on
        // macOS 27 the catcher intercepts the system's own pill.
        DispatchQueue.main.async { [weak self, weak item] in
            StatusItemHighlight.makeRoom(for: item?.button)
            self?.statusItemCatcher = StatusItemCatcher.over(item?.button) { [weak self] in self?.togglePanel() }
        }
        if #available(macOS 26.0, *) {
            OSDBannerService.shared.statusItem = item
            OSDBannerService.shared.setHighlight = { [weak self] lit in
                guard let self else { return }
                self.bannerLightsStatusItem = lit
                self.refreshStatusItemLight()
            }
            // The banner's own track, dragged with the pointer, goes to the
            // same services the keys use.
            OSDBannerService.shared.onSlide = { [weak self] displayID, image, fraction in
                guard let display = self?.displayManager.displays.first(where: { $0.displayID == displayID })
                else { return }
                switch image {
                case .volume, .mute:
                    VolumeService.shared.setVolume(fraction * 100, for: display)
                case .brightness, .eject:
                    let target = fraction * display.maxBrightness
                    display.brightness = target
                    Task { await BrightnessService.shared.setBrightness(target, for: display) }
                }
            }
        }

        // Small dot on the icon shows Keep Awake is on, at a glance. (keep-awake indicator)
        updateStatusIcon(active: KeepAwakeService.shared.isActive, animated: false)
        keepAwakeCancellable = KeepAwakeService.shared.$isActive
            .sink { [weak self] active in self?.updateStatusIcon(active: active, animated: true) }
    }

    /// Fades a small orange dot in/out over the (unchanged) menu-bar icon to reflect Keep Awake.
    /// Only the dot animates; the base symbol stays put. (keep-awake indicator)
    private func updateStatusIcon(active: Bool, animated: Bool) {
        guard let button = statusItem?.button else { return }
        let badge = keepAwakeBadge ?? makeKeepAwakeBadge(on: button)
        keepAwakeBadge = badge
        let target: CGFloat = active ? 1 : 0
        guard animated else { badge.alphaValue = target; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            badge.animator().alphaValue = target
        }
    }

    /// A small orange dot pinned to the icon's bottom-right corner, layer-backed so its alpha can
    /// animate. Starts hidden (alpha 0); updateStatusIcon fades it in when Keep Awake turns on.
    /// (keep-awake indicator)
    private func makeKeepAwakeBadge(on button: NSStatusBarButton) -> NSView {
        let d: CGFloat = 6
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dot.layer?.cornerRadius = d / 2
        dot.alphaValue = 0
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)
        // Pinned to the centred icon, not the button: the macOS 27 button is wider and taller.
        let icon = button.image?.size ?? .zero
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: d),
            dot.heightAnchor.constraint(equalToConstant: d),
            dot.trailingAnchor.constraint(equalTo: button.centerXAnchor, constant: icon.width / 2 + 1),
            dot.bottomAnchor.constraint(equalTo: button.centerYAnchor, constant: icon.height / 2 + 1)
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
        // Static-window architecture (docs/panel-resize.md): the window never
        // resizes mid-animation; the shell inside it animates as pure layer
        // work, with the shadow as a CALayer twin resizing in the same commit.
        let windowW = canvas.width + canvas.sideMargin * 2
        let root = PanelRootView(frame: NSRect(x: 0, y: 0, width: windowW, height: 480))
        let shadow = NSView(frame: .zero)
        let shadowLayer = CALayer()
        shadowLayer.masksToBounds = false
        // Shadow twin: outset, calibrated border and alpha (PanelCanvas sets the
        // rest per flight). See docs/panel-resize.md (Shadow twin).
        shadowLayer.borderWidth = 2
        shadowLayer.borderColor = NSColor.black.withAlphaComponent(0.29).cgColor
        shadowLayer.cornerRadius = 17
        // Knockout mask removes the shadow's interior so the glass backdrop
        // never samples it. See docs/panel-resize.md (Shadow twin).
        let knockout = CAShapeLayer()
        knockout.fillRule = .evenOdd
        shadowLayer.mask = knockout
        shadow.layer = shadowLayer
        shadow.wantsLayer = true
        // Set through the view API (AppKit syncs shadow -> layer only on a
        // display pass); shadowPath stays explicit so per-tick resizes stay
        // cheap. See docs/panel-resize.md (Shadow twin).
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
        // Flights redraw the native rim's white line as this border (width
        // toggled in PanelCanvas); the black line lives on the shadow twin.
        // See docs/panel-resize.md (Shadow twin).
        shell.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        // macOS 26 Liquid Glass, the material Control Center panels use. Its
        // materialize bloom plays only once, here during hidden warm-up; the
        // panel never orders out afterwards.
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
        // Oversized fixed canvas glued to the shell top, clipped by the shell's
        // rounded mask: resizing the shell only MOVES the glass layer.
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
            // Blocks near the window's edges otherwise get a phantom safe-area
            // inset, misplacing clicks. See docs/panel-resize.md (failure map #9).
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
            // Split so every dropdown is its own block: the canvas clips content
            // rendered once at natural height (the 120Hz fix; docs/panel-resize.md).
            // Each detail block paints its shaded band on the clip layer (banded).
            let modeC = DisplayModeController(display: display, displayManager: dm)
            let colorModeC = DisplayColorModeController(display: display)
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
            blocks.append(detail("dcolor-head", isOpen: detailOpen, live: true) {
                ColorModeHeadBlock(controller: colorModeC, state: state)
            })
            blocks.append(detail("dcolor-body", isOpen: {
                detailOpen() && state.colorModeOpenIDs.contains(id)
            }) {
                ColorModeListBlock(controller: colorModeC)
            })
            blocks.append(detail("dcolor-tail", isOpen: detailOpen) {
                ColorModeTailBlock(controller: colorModeC)
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
                EdgeCrossingRow()
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

    /// True while the pointer sits over Crisp's own status item: presses there
    /// are the click interceptor's to toggle, so the panel's auto-dismiss paths
    /// treat them as neither a dismissal nor a click-away.
    private var isPointerOverStatusItem: Bool {
        StatusItemHighlight.isPointerOver(statusItem?.button)
    }

    /// Lights the menu bar item while the panel or the banner is up.
    private func refreshStatusItemLight() {
        StatusItemHighlight.apply(isPanelShown || bannerLightsStatusItem,
                                  to: statusItem?.button)
    }

    @objc private func togglePanel() {
        if isPanelShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    /// Display the open panel was summoned on, by stable UUID (displayIDs are
    /// reassigned across a soft-reconnect); `preferOrigin` re-anchors here once
    /// that display is back online after migrating away.
    private var panelOriginDisplayUUID: String?

    private func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String
    }

    /// Anchors the panel under the status item on whatever screen it lives on.
    /// Called on open and whenever screen parameters change (e.g. the main
    /// display switching re-origins global coordinates).
    private func positionPanel(_ p: MenuPanel, preferOrigin: Bool = false) {
        guard let btnWindow = statusItem?.button?.window else { return }
        let btnFrame = btnWindow.frame
        let btnScreen = btnWindow.screen ?? NSScreen.main
        var screen = btnScreen
        var anchorMidX = btnFrame.midX
        var topY = btnFrame.minY - 1
        // macOS 27's status item window reaches 3pt past the menu bar, so anchor
        // to the bar's own bottom edge instead, when there is one.
        if SystemLook.isMacOS27OrLater, let screen = btnScreen,
           screen.frame.maxY - screen.visibleFrame.maxY > 1 {
            topY = screen.visibleFrame.maxY - 1
        }
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

        // Kicks the refresh of everything that can drift while closed, NOW at
        // the click: reads run off the main thread and land during the fade-in,
        // so sliders are correct once the panel is readable.
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

        // Re-applies appearance-tied rim/shadow before becoming visible: colors
        // are otherwise only refreshed on a flight, so first open or a mode
        // switch would show the wrong rim until an expansion fixed it.
        canvas.refreshAppearance()

        p.ignoresMouseEvents = false
        // First open only: fade in briefly so one-time on-screen costs (Liquid
        // Glass materialize bloom, first rasterization) play under the fade
        // rather than glitching in visibly. Later opens stay instant.
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
        // The panel carries brightness and volume on its own sliders, so the
        // OSD stays away while it is open.
        BrightnessHUDService.shared.suppressed = true
        // Native items keep the menu bar button lit while their panel is open.
        refreshStatusItemLight()

        // Re-sync views that mirror live external state (e.g. the system auto-brightness
        // toggle) on every open; the panel content mounts once, so their .onAppear
        // won't re-fire here.
        NotificationCenter.default.post(name: .crispPanelDidOpen, object: nil)

        // Re-probes DDC volume for externals that haven't answered yet: the
        // connect-time probe can land in the post-link-training garbage window,
        // and nothing else retries. A success is remembered so this stops firing.
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
                    // Don't dismiss for our own admin auth dialog, an in-panel alert,
                    // or a tracking menu: an outside-panel click there cancels the
                    // MENU (below), not the panel. Excludes the shadow margins.
                    let visible = self.canvas.visibleScreenFrame()
                    if PanelOpenGuard.isMenuTracking {
                        if !visible.contains(NSEvent.mouseLocation) {
                            self.trackingMenu?.cancelTracking()
                        }
                        return
                    }
                    if PanelOpenGuard.suppressAutoDismiss
                        || PanelOpenGuard.isConfirmationActive { return }
                    // Global monitors normally fire only for clicks in other apps, but the
                    // dark-mode crossfade's snapshot overlay intercepts every click too.
                    // Close only when the cursor is genuinely outside the panel or status item.
                    if visible.contains(NSEvent.mouseLocation) || self.isPointerOverStatusItem { return }
                    self.closePanel()
                }
            }
        }
    }

    private func closePanel() {
        guard let p = panel, isPanelShown else { return }
        isPanelShown = false
        BrightnessHUDService.shared.suppressed = false
        // The banner may be up, and it holds the same light.
        refreshStatusItemLight()
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
        // Order matters: isFloatingPanel assigns the window level (.floating, 3),
        // so setting it after silently discards the level and the panel runs
        // below other apps' utility windows.
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isOpaque = false
        p.backgroundColor = .clear
        // Shadow is a CALayer twin (PanelCanvas), not the WindowServer's. See
        // docs/panel-resize.md (Shadow twin).
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
}

// MARK: - NSWindowDelegate

extension AppDelegate {
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
            // Takes key, but isn't a click-away: the press is on Crisp's own
            // status item, whose interceptor already owns the toggle. Closing
            // here too would let that toggle reopen the panel it just hid.
            if isPointerOverStatusItem { return }
            // Same crossfade caveat as the click monitor: the snapshot window can
            // steal key mid-click inside the panel. Test the visible shell
            // (window frame includes shadow margins).
            if canvas.visibleScreenFrame().contains(NSEvent.mouseLocation) { return }
            closePanel()
        }
    }
}
