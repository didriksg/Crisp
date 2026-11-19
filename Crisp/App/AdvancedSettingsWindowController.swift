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
    static let contentWidth: CGFloat = 520
    private let displayManager: DisplayManager
    private var displaysWatch: AnyCancellable?
    /// Each tab's full height, as it last reported it.
    private var heights: [String: CGFloat] = [:]

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
        // With keyboard navigation on, AppKit would ring the first switch at once.
        window?.makeFirstResponder(nil)
    }

    private func makeWindow() -> NSWindow {
        let savedTab = UserDefaults.standard.string(forKey: AdvancedSettingsTabs.lastTabKey)
        let tabs = AdvancedSettingsTabs()
        tabs.tabStyle = .toolbar
        // No resize animation (Didrik, 2026-11-19): the tab controller animated only a
        // tab's first showing, so switching felt different each time.
        tabs.transitionOptions = []
        tabs.onSelect = { [weak self] in self?.fit() }
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
        // The tab controller sizes the window and the tab's view from the tab's
        // preferredContentSize. The hosting controller updated it only at a later layout
        // (focus loss), so the tab reports its full height at once and fit() sets it. The
        // scroll view takes over where the screen ends.
        let root = ScrollView {
            view
                .environmentObject(displayManager)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    MainActor.assumeIsolated {
                        self?.heights[symbol] = height
                        self?.fit()
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        host.title = label  // the tab controller passes it on as the window title
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.identifier = symbol  // stable across languages, for the saved last tab
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    /// Sizes the selected tab to its full height, or to the room left above the bottom of
    /// the screen, where it scrolls. The window keeps its top edge (AdvancedSettingsWindow).
    private func fit() {
        guard let window, let tabs = window.contentViewController as? NSTabViewController,
              tabs.tabViewItems.indices.contains(tabs.selectedTabViewItemIndex) else { return }
        let item = tabs.tabViewItems[tabs.selectedTabViewItemIndex]
        guard let tab = item.identifier as? String, let full = heights[tab], full > 0 else { return }
        var height = full
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let chrome = window.frame.height - window.contentLayoutRect.height  // title bar and toolbar
            height = min(full, window.frame.maxY - chrome - visible.minY)
        }
        let size = NSSize(width: Self.contentWidth, height: height)
        if item.viewController?.preferredContentSize != size { item.viewController?.preferredContentSize = size }
    }

    /// A smaller screen may need a shorter window.
    func windowDidChangeScreen(_ notification: Notification) {
        fit()
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
    var onSelect: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(id, forKey: Self.lastTabKey)
        }
        view.window?.makeFirstResponder(nil)  // no focus ring on the new tab's first control
        onSelect?()
    }
}

/// Closes on Cmd-W itself (an accessory app's stock menu is not known to carry a Close
/// item) and on Esc. A shortcut recording takes Esc first, to cancel the recording.
private final class AdvancedSettingsWindow: NSWindow {
    /// Every height change keeps the top edge, as Apple's settings windows grow down, and
    /// stops at the bottom of the screen. The tab controller resizes from the bottom edge.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible, rect.height != frame.height {
            rect.origin.y = frame.maxY - rect.height
            if let bottom = screen?.visibleFrame.minY, rect.minY < bottom {
                rect.size.height = rect.maxY - bottom
                rect.origin.y = bottom
            }
        }
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
