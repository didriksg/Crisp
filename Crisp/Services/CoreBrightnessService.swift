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
    private(set) var trueToneAvailable = false
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
    }

    /// Re-read the current system state (the user may have toggled it via Control Center).
    /// The reads are XPC round-trips, so they run off the main thread to keep
    /// panel opening snappy; results publish back on main.
    func refresh() {
        let blueClient = blueLightClient
        let ttClient = trueToneClient
        let ttAvailable = trueToneAvailable
        DispatchQueue.global(qos: .userInitiated).async {
            var nightShift: Bool?
            if let c = blueClient {
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
            if let c = ttClient, ttAvailable {
                trueTone = Self.boolCall(c, "enabled")
            }
            let dark = _SLSGetAppearanceTheme?()
            DispatchQueue.main.async {
                if let nightShift { self.nightShiftEnabled = nightShift }
                if let trueTone { self.trueToneEnabled = trueTone }
                // Don't clobber an optimistic toggle: the async theme change
                // may still be in flight, and a stale read here snaps the
                // button back for a beat (the native control never does).
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
        // The eased color crossfade is AppKit's private NSGlobalPreferenceTransition:
        // grab a transition, flip the theme silently, then post the change through
        // the transition so every app animates. Same path System Settings and
        // Control Center use; plain SLS notify (and System Events) flip instantly.
        // Acquiring the transition BLOCKS in the window server while it snapshots
        // every display, so the whole dance runs off the main thread; the toggle
        // above renders instantly, like the native control.
        Task.detached(priority: .userInitiated) {
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
