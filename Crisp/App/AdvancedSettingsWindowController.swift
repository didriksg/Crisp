import AppKit
import Combine
import SwiftUI

/// The Advanced Settings window: configuration that Crisp works without (docs/DESIGN.md,
/// "Advanced Settings window"). AppKit owns the window and the toolbar tabs, SwiftUI draws
/// each tab. The SwiftUI Settings scene is not used: it opens only from a view inside a
/// scene, and the panel's views have none (docs/best-practice/settings-window.md).
@MainActor
final class AdvancedSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let virtualDisplaysTab = "display.2"
    private let displayManager: DisplayManager
    private var displaysWatch: AnyCancellable?

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `tab` is a tab's identifier (its symbol name) to open on, or nil for the last tab.
    func show(tab: String? = nil) {
        if window == nil { window = makeWindow() }
        if let tab, let tabs = window?.contentViewController as? NSTabViewController {
            let index = tabs.tabView.indexOfTabViewItem(withIdentifier: tab)
            if index != NSNotFound { tabs.selectedTabViewItemIndex = index }
        }
        // A Dock icon and a Cmd-Tab entry while the window is open (Didrik, 2026-11-18): an
        // accessory app's window behind other apps could not be found again.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let savedTab = UserDefaults.standard.string(forKey: AdvancedSettingsTabs.lastTabKey)
        let tabs = AdvancedSettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab(AdvancedGeneralTab(), label: String(localized: "General"), symbol: "gearshape"))
        tabs.addTabViewItem(tab(AdvancedKeyboardTab(), label: String(localized: "Keyboard"), symbol: "keyboard"))
        tabs.addTabViewItem(tab(AdvancedVirtualDisplaysTab(), label: String(localized: "Virtual Displays"),
                                symbol: Self.virtualDisplaysTab))
        let displaysTab = tab(AdvancedDisplaysTab(), label: String(localized: "Displays"), symbol: "display")
        // The Displays tab is there only while it has a display to list.
        // DisplayManager publishes on the main thread.
        displaysWatch = displayManager.$displays.sink { [weak tabs] displays in
            MainActor.assumeIsolated {
                guard let tabs else { return }
                let show = !advancedSettingsDisplays(displays).isEmpty
                let shown = tabs.tabViewItems.contains(displaysTab)
                if show, !shown { tabs.insertTabViewItem(displaysTab, at: min(2, tabs.tabViewItems.count)) }  // after Keyboard
                if !show, shown { tabs.removeTabViewItem(displaysTab) }
            }
        }

        if let savedTab {
            let index = tabs.tabView.indexOfTabViewItem(withIdentifier: savedTab)
            if index != NSNotFound { tabs.selectedTabViewItemIndex = index }
        }

        let window = AdvancedSettingsWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // fullScreenAuxiliary: the panel needed it to show over a full-screen app.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        let name = "CrispAdvancedSettings"
        if !window.setFrameUsingName(name) { window.center() }
        window.setFrameAutosaveName(name)
        return window
    }

    private func tab(_ view: some View, label: String, symbol: String) -> NSTabViewItem {
        // A row shown or hidden inside a tab changes its height, but the tab controller
        // resizes the window only on a tab switch, and the hosting controller's size
        // catches up only at a later layout (focus loss). So the tab reports its own
        // height, measured at its ideal size, and the window follows at once.
        let root = view
            .environmentObject(displayManager)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                MainActor.assumeIsolated { self?.fit(symbol, height: height) }
            }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        host.title = label  // the tab controller passes it on as the window title
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.identifier = symbol  // stable across languages, for the saved last tab
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    /// Sizes the window to the selected tab's height, top edge fixed.
    private func fit(_ tab: String, height: CGFloat) {
        guard let window, let tabs = window.contentViewController as? NSTabViewController,
              tabs.tabViewItems.indices.contains(tabs.selectedTabViewItemIndex),
              tabs.tabViewItems[tabs.selectedTabViewItemIndex].identifier as? String == tab,
              height > 0 else { return }
        let old = window.frame
        let width = window.contentRect(forFrameRect: old).width
        let size = NSSize(width: width, height: height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        guard frame.size != old.size else { return }
        window.setFrame(frame, display: true, animate: true)
    }

    func windowWillClose(_ notification: Notification) {
        // A recording in this window must not leave every hotkey suspended.
        NotificationCenter.default.post(name: .crispStopShortcutRecording, object: nil)
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Remembers the last tab across launches, as the HIG asks of a settings window.
private final class AdvancedSettingsTabs: NSTabViewController {
    static let lastTabKey = "crisp.advancedSettingsLastTab"

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(id, forKey: Self.lastTabKey)
        }
    }
}

/// Closes on Cmd-W itself (an accessory app's stock menu is not known to carry a Close
/// item) and on Esc. A shortcut recording takes Esc first, to cancel the recording.
private final class AdvancedSettingsWindow: NSWindow {
    /// Every height change keeps the top edge, as Apple's settings windows grow down. The
    /// window also resizes itself to the tab's new size a moment after `fit`, from the
    /// bottom edge, and whichever ran last won.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible, rect.height != frame.height { rect.origin.y = frame.maxY - rect.height }
        super.setFrame(rect, display: flag)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
