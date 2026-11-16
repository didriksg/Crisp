# Settings window in an accessory menu bar app

Date: 2026-11-16, revised the same day after an EGM review. Applies to Crisp (Swift 6, deployment target macOS 14, built on the macOS 26 SDK in CI and the macOS 27 SDK on Didrik's Mac, runs on 14, 15, 26 and 27). Serves the Advanced Settings window spec (`docs/superpowers/specs/2026-11-16-advanced-settings-window-design.md`). Check it again after 2027-05-16.

## Recommendation

Build the Advanced Settings window in AppKit: an `NSWindowController` that owns a titled `NSWindow`, whose content is an `NSTabViewController` with `tabStyle = .toolbar` and one `NSHostingController` for each tab (General, Keyboard, Displays). Put it in its own file, because `AppDelegate` is at its length limit. The panel row calls a closure from `AppDelegate` that first closes the panel and then shows the window.

Do not use the SwiftUI `Settings` scene or a `Window` scene. Both open only from a SwiftUI view inside a scene, and the panel's views are hosted outside one. The community record shows that this path broke on macOS 14 and again on 26. The AppKit path does not depend on SwiftUI scenes at all.

The open risk is the same for every option: the window must come in front and become key. Since macOS 14, `NSApp.activate()` is only a request, and macOS can refuse it for an app with no Dock icon. The live test below decides which activation call Crisp uses.

## Why not the SwiftUI scenes

The `Settings` scene opens through `openSettings` or `SettingsLink`, which exist from macOS 14 (Apple documentation). Apple does not say whether they work from a view that is hosted outside a scene. Developers report three problems. The old `showSettingsWindow:` selector stopped working on macOS 14. `openSettings` worked on 15 but did nothing on 26 when no SwiftUI view tree was live. The workaround is a hidden window and short delays (Peter Steinberger, 2025; the SettingsAccess package says it cannot be used from outside a SwiftUI view). A single short test on this Mac (macOS 27.0.1, see Evidence) opened the `Settings` window from a hosted panel. So that path may work on 27, but it is not tested on 14, 15 or 26.

A `Window` scene opens through `openWindow`. It needs the same scene environment and adds nothing that the AppKit window does not give.

What the AppKit window loses, and how it gets it back: toolbar tabs and a title that follows the tab come from `NSTabViewController.TabStyle.toolbar`, which is the documented AppKit style for preference windows. Cmd-W and Cmd-, need code (see Keys and menus).

## Activation

Documentation says three things. `NSApplication.activate()` (macOS 14 and later) "doesn't guarantee app activation". Activation is cooperative: the active app can pass it on with `yieldActivation(to:)`, but only the active app can call that, so it does not help Crisp. The documentation page for `activate(ignoringOtherApps:)` says "This method will be deprecated in a future release. Use NSApp.activate instead." On the macOS 27 SDK it still compiles under Swift 6 with no warning (typechecked on 2026-11-16), so `make test`, which treats warnings as errors, accepts it.

Apple forum thread "activate() in a menu bar app" (836619, 2026) has two sides. The developer who asked reports that `activate()` does not bring an accessory app's window in front of another app's window, and that switching to `.regular` also failed in a SwiftUI sample. That developer filed FB23508310. The Apple engineer said that the stricter model is intentional and still recommended `activate()` or `openWindow`.

Evidence from Crisp itself: `UpdateService.installUpdate()` calls `NSApp.activate()` from a panel row, and Sparkle's window comes in front. This is a real click, but not proof for macOS 27.

Today the panel takes key while Crisp is not active (`.nonactivatingPanel`, `makeKey`). That is why the shortcut recorders work in the panel. A titled window is different: if activation fails, the window shows but gets no keys, so the recorders do not work. `orderFrontRegardless()` would make the window visible without making it key and would hide that failure, so do not use it.

Activation calls to try, in this order, and stop at the first that passes the live test:

1. `NSApp.activate()`, called in the same click, before `makeKeyAndOrderFront(nil)`.
2. `NSApp.activate(ignoringOtherApps: true)`. It keeps the policy and gives no warning today.
3. A titled `NSPanel` with `.nonactivatingPanel`, which takes key without app activation, as the menu panel does. This is a judgment, not tested.
4. A temporary `.regular` activation policy while the window is open, which shows a Dock icon. This goes against the spec, so only on Didrik's word.

## Window setup

```swift
@MainActor
final class AdvancedSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let displayManager: DisplayManager

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate()                      // the live test picks the call (see Activation)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab(GeneralTab(), label: "General", symbol: "gearshape"))
        // Keyboard and Displays the same way.
        let w = AdvancedSettingsWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]   // fixed size, no resize
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.delegate = self
        if !w.setFrameUsingName("CrispAdvancedSettings") { w.center() }
        w.setFrameAutosaveName("CrispAdvancedSettings")
        return w
    }

    private func tab(_ view: some View, label: String, symbol: String) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: NSHostingController(rootView: view.environmentObject(displayManager)))
        item.label = String(localized: String.LocalizationValue(label))
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    func windowWillClose(_ notification: Notification) {
        // A recording in this window must not leave every hotkey suspended.
        NotificationCenter.default.post(name: .crispStopShortcutRecording, object: nil)
    }
}
```

Every view that reads `@EnvironmentObject var displayManager` needs the injection above; the moved settings rows do, and without it they crash. `.fullScreenAuxiliary` is there because the menu panel needed it to show over a full-screen app; `.moveToActiveSpace` alone has only a one-line description in the documentation. The first open centers the window on the main screen; later opens use the saved frame. The existing `windowDidResignKey` handler checks for `MenuPanel` first, so it ignores this window. Any new `NotificationCenter` observer with `queue: .main` wraps its body in `MainActor.assumeIsolated`, as the existing ones in `AppDelegate` do, because Swift 6 does not treat those closures as main actor.

Panel row: the panel does not close by itself on this click, because its resign-key handler returns early while the pointer is inside the panel, and the panel sits at `.popUpMenu` level above normal windows. So `AppDelegate` passes a closure into `SettingsView` (built in `rebuildBlocksIfNeeded`) that calls `closePanel()` and then `advancedSettings.show()`, in that order.

## Keys and menus

Cmd-W: no source says the stock menu has a Close item for an accessory app, so the window closes itself on Cmd-W:

```swift
final class AdvancedSettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" { performClose(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
}
```

Cmd-,: a SwiftUI `App` installs a main menu with "Settings…" on Cmd-, even in an accessory app (seen on macOS 27 in the test below). While the new window makes Crisp active, Cmd-, would open the empty `Settings { EmptyView() }` window. The scene must stay, because the `App` body needs one, so replace its menu item: `Settings { EmptyView() }.commands { CommandGroup(replacing: .appSettings) {} }` (typechecked). The empty group removes the item. A group with a button that calls `show()` would make Cmd-, a second way in, which the spec does not allow today.

Shortcut recorders: the recorder stops on `.crispPanelDidClose`, on `.crispStopShortcutRecording` and on disappear. In the window, a panel close must not stop a recording, so the rows in the window ignore `.crispPanelDidClose`. Do not stop on resign key: the OSD banner takes key on hover.

## Live test (decides activation)

Pass means all three are true after a real click on "Advanced Settings…" with another app in front: `NSApp.isActive`, `window.isKeyWindow`, and a shortcut records in the Keyboard tab. Run it several times from a desktop Space and from a full-screen Space, on macOS 27 on Didrik's Mac and on 14 and 15 in the tart VMs. Also check Cmd-W, that Cmd-, does nothing, and that closing the window during a recording leaves the existing hotkeys working. Not measured yet: all of this.

## Evidence on this Mac

One short test program on 2026-11-16, macOS 27.0.1, one run each, started from a shell with no real click: `openSettings` from a hosted borderless panel opened the `Settings` window; with another app in front, `activate()`, `activate(ignoringOtherApps: true)` and a switch to `.regular` all left the app inactive and the window not key; the SwiftUI `App` main menu had "Settings…" on Cmd-,. Because there was no user click, this does not show what a real click does. The program was not kept.

## Where Crisp deviates and why

None yet. If the live test needs step 4 of Activation, that deviates from the spec and goes to Didrik first.

## Sources (accessed 2026-11-16)

- Apple, OpenSettingsAction: https://developer.apple.com/documentation/swiftui/opensettingsaction
- Apple, SettingsLink: https://developer.apple.com/documentation/swiftui/settingslink
- Apple, NSApplication.activate(): https://developer.apple.com/documentation/appkit/nsapplication/activate()
- Apple, activate(ignoringOtherApps:): https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:)
- Apple, Passing control from one app to another with cooperative activation: https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation
- Apple, NSTabViewController.TabStyle.toolbar: https://developer.apple.com/documentation/appkit/nstabviewcontroller/tabstyle-swift.enum/toolbar
- Apple, moveToActiveSpace: https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/movetoactivespace
- Apple, setFrameAutosaveName(_:): https://developer.apple.com/documentation/appkit/nswindow/setframeautosavename(_:)
- Apple Developer Forums, "activate() in a menu bar app" (thread 836619): https://developer.apple.com/forums/thread/836619
- Apple Developer Forums, "Opening SwiftUI Settings from AppKit" (thread 739831, no Apple answer): https://developer.apple.com/forums/thread/739831
- Peter Steinberger, "Showing Settings from macOS menu bar items" (2025): https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items
- SettingsAccess (orchetect): https://github.com/orchetect/SettingsAccess
