import Foundation

// SkyLight private API: read/toggle system dark mode
private let _SLSGetAppearanceTheme: (@convention(c) () -> Bool)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let sym = dlsym(h, "SLSGetAppearanceThemeLegacy") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) () -> Bool).self)
}()
private let _SLSSetAppearanceTheme: (@convention(c) (Bool) -> Void)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let sym = dlsym(h, "SLSSetAppearanceThemeLegacy") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Bool) -> Void).self)
}()
// Animated variant: with notify=true the switch goes through the same crossfade
// Control Center uses, instead of the instant Legacy flip.
private let _SLSSetAppearanceThemeNotifying: (@convention(c) (Bool, Bool) -> Void)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let sym = dlsym(h, "SLSSetAppearanceThemeNotifying") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Bool, Bool) -> Void).self)
}()

/// System-level Night Shift / True Tone / Dark Mode switches, implemented via private frameworks
/// (CoreBrightness's CBBlueLightClient / CBTrueToneClient + SkyLight).
/// Per project convention, loaded at runtime with dlopen + NSClassFromString/dlsym; private frameworks are not linked.
@MainActor
final class CoreBrightnessService: ObservableObject {
    static let shared = CoreBrightnessService()

    @Published var nightShiftEnabled = false
    @Published var trueToneEnabled = false
    @Published var darkModeEnabled = false
    private(set) var nightShiftAvailable = false
    // Published because availability changes at runtime: CBTrueToneClient reports
    // available=false in clamshell, so an app launched lid-closed must un-latch later.
    @Published private(set) var trueToneAvailable = false
    var darkModeAvailable: Bool { _SLSGetAppearanceTheme != nil && _SLSSetAppearanceTheme != nil }

    private var blueLightClient: NSObject?
    private var trueToneClient: NSObject?

    private init() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil else { return }
        if let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type {
            blueLightClient = cls.init()
            nightShiftAvailable = true
        }
        if let cls = NSClassFromString("CBTrueToneClient") as? NSObject.Type {
            let client = cls.init()
            trueToneClient = client
            trueToneAvailable = Self.boolCall(client, "supported") && Self.boolCall(client, "available")
        }
        refresh()
        observeSystemChanges()
    }

    /// Keeps published state live while the panel is closed, so it opens
    /// already correct. Dark mode arrives via a distributed notification;
    /// Night Shift and True Tone via a CoreBrightness status callback; both
    /// just call refresh(), event-driven, never polled.
    private func observeSystemChanges() {
        // Dark mode: Control Center / System Settings post this app-wide.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Night Shift / True Tone: each client invokes this block on any status change.
        // responds(to:) guards a client that lacks the selector.
        let onChange: @convention(block) () -> Void = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        let sel = NSSelectorFromString("setStatusNotificationBlock:")
        for client in [blueLightClient, trueToneClient].compactMap({ $0 }) where client.responds(to: sel) {
            typealias Fn = @convention(c) (NSObject, Selector, @convention(block) () -> Void) -> Void
            unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, onChange)
        }
    }

    /// Re-read the current system state (the user may have toggled it via Control Center).
    /// The reads are XPC round-trips, so they run off the main thread to keep
    /// panel opening snappy; results publish back on main.
    func refresh() {
        // The CoreBrightness XPC client objects are safe to message from any
        // thread, but NSObject is not Sendable; box them across the hop.
        let blueBox = UncheckedSendable(value: blueLightClient)
        let ttBox = UncheckedSendable(value: trueToneClient)
        DispatchQueue.global(qos: .userInitiated).async {
            var nightShift: Bool?
            if let c = blueBox.value {
                var buf = [UInt8](repeating: 0, count: 64)
                let sel = NSSelectorFromString("getBlueLightStatus:")
                if c.responds(to: sel) {
                    typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool
                    let ok = buf.withUnsafeMutableBytes {
                        unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, $0.baseAddress!)
                    }
                    // Status struct layout {BOOL active, BOOL enabled, ...}, enabled is at offset 1
                    if ok { nightShift = buf[1] != 0 }
                }
            }
            var trueTone: Bool?
            var ttAvailable = false
            if let c = ttBox.value {
                // Re-check every refresh: availability flips with the lid (clamshell
                // hides True Tone system-wide), and init may have run lid-closed.
                ttAvailable = Self.boolCall(c, "supported") && Self.boolCall(c, "available")
                if ttAvailable { trueTone = Self.boolCall(c, "enabled") }
            }
            let dark = _SLSGetAppearanceTheme?()
            DispatchQueue.main.async {
                if let nightShift { self.nightShiftEnabled = nightShift }
                if self.trueToneAvailable != ttAvailable { self.trueToneAvailable = ttAvailable }
                if let trueTone { self.trueToneEnabled = trueTone }
                // Don't clobber an optimistic toggle while the async theme
                // change may still be in flight (see docs/brightness-notes.md).
                if let dark, Date().timeIntervalSince(self.lastDarkModeSetAt) > 3.0 {
                    self.darkModeEnabled = dark
                }
            }
        }
    }

    private var lastDarkModeSetAt = Date.distantPast

    func setDarkMode(_ on: Bool) {
        darkModeEnabled = on
        lastDarkModeSetAt = Date()
        // Crossfades via AppKit's private NSGlobalPreferenceTransition, the
        // same path System Settings and Control Center use. Acquiring it
        // BLOCKS in the window server, so this runs off the main thread; see
        // docs/brightness-notes.md (CoreBrightness).
        Task.detached(priority: .userInitiated) {
            // Let the flipped control reach the screen first: the transition
            // must snapshot it already released and re-tinted.
            try? await Task.sleep(nanoseconds: 120_000_000)
            let transition = (NSClassFromString("NSGlobalPreferenceTransition") as? NSObject.Type)?
                .perform(NSSelectorFromString("transition"))?.takeUnretainedValue() as? NSObject
            if let setNotifying = _SLSSetAppearanceThemeNotifying {
                setNotifying(on, transition == nil)
            } else {
                _SLSSetAppearanceTheme?(on)
            }
            if let transition {
                let sel = NSSelectorFromString("postChangeNotification:completionHandler:")
                typealias Post = @convention(c) (NSObject, Selector, Int, @escaping @convention(block) () -> Void) -> Void
                // Completion keeps the transition alive until the crossfade finishes.
                unsafeBitCast(transition.method(for: sel), to: Post.self)(transition, sel, 0, { _ = transition })
            }
        }
    }

    func setNightShift(_ on: Bool) {
        guard let c = blueLightClient else { return }
        Self.setBoolCall(c, "setEnabled:", on)
        nightShiftEnabled = on
    }

    func setTrueTone(_ on: Bool) {
        guard let c = trueToneClient else { return }
        Self.setBoolCall(c, "setEnabled:", on)
        trueToneEnabled = on
    }

    /// Toggles True Tone off and back on to clear a stale tint an external
    /// keeps after a full wake (issue #131). See docs/brightness-notes.md
    /// (CoreBrightness). Reads state live, never the published value, so a
    /// stale read can't switch True Tone on for someone who has it off.
    @discardableResult
    func reassertTrueTone() -> Bool {
        guard let c = trueToneClient, Self.boolCall(c, "supported"), Self.boolCall(c, "available"),
              Self.boolCall(c, "enabled") else { return false }
        Self.setBoolCall(c, "setEnabled:", false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.setBoolCall(c, "setEnabled:", true)
            self.trueToneEnabled = true
        }
        return true
    }

    // MARK: - ObjC runtime call helpers

    private nonisolated static func boolCall(_ obj: NSObject, _ name: String) -> Bool {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(obj.method(for: sel), to: Fn.self)(obj, sel)
    }

    private nonisolated static func setBoolCall(_ obj: NSObject, _ name: String, _ v: Bool) {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(obj.method(for: sel), to: Fn.self)(obj, sel, v)
    }
}

/// Carries a value across a `@Sendable` boundary the compiler cannot verify.
/// Only for objects that are documented or observed thread-safe to message
/// (here: the CoreBrightness XPC client objects).
private struct UncheckedSendable<T>: @unchecked Sendable { let value: T }
