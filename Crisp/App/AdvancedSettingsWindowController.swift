import AppKit
import Combine
import SwiftUI

/// The Advanced Settings window: configuration that Crisp works without (docs/DESIGN.md,
/// "Advanced Settings window"). AppKit owns the window and the toolbar tabs, SwiftUI draws
/// each tab. The SwiftUI Settings scene is not used: it opens only from a view inside a
/// scene, and the panel's views have none (docs/best-practice/settings-window.md).
@MainActor
final class AdvancedSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let displayManager: DisplayManager
    private var displaysWatch: AnyCancellable?

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        if window == nil { window = makeWindow() }
        // A request on macOS 14 and later; the live test in the best-practice note
        // decides whether this is enough.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let savedTab = UserDefaults.standard.string(forKey: AdvancedSettingsTabs.lastTabKey)
        let tabs = AdvancedSettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab(AdvancedGeneralTab(), label: String(localized: "General"), symbol: "gearshape"))
        tabs.addTabViewItem(tab(AdvancedKeyboardTab(), label: String(localized: "Keyboard"), symbol: "keyboard"))
        let displaysTab = tab(AdvancedDisplaysTab(), label: String(localized: "Displays"), symbol: "display")
        // The Displays tab is there only while it has a display to list.
        // DisplayManager publishes on the main thread.
        displaysWatch = displayManager.$displays.sink { [weak tabs] displays in
            MainActor.assumeIsolated {
                guard let tabs else { return }
                let show = !advancedSettingsDisplays(displays).isEmpty
                let shown = tabs.tabViewItems.contains(displaysTab)
                if show, !shown { tabs.addTabViewItem(displaysTab) }
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
        let host = NSHostingController(rootView: view.environmentObject(displayManager))
        host.sizingOptions = .preferredContentSize
        host.title = label  // the tab controller passes it on as the window title
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.identifier = symbol  // stable across languages, for the saved last tab
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    func windowWillClose(_ notification: Notification) {
        // A recording in this window must not leave every hotkey suspended.
        NotificationCenter.default.post(name: .crispStopShortcutRecording, object: nil)
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
