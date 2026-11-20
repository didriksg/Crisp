import AppKit
import Combine

/// The opt-in cup in the menu bar (#266): a click turns Keep Awake on or off with no limit,
/// a right click opens a menu with the time limits. Shown while the setting is on.
@MainActor
final class KeepAwakeStatusItem: NSObject {
    private var item: NSStatusItem?
    private var cancellable: AnyCancellable?

    override init() {
        super.init()
        let keepAwake = KeepAwakeService.shared
        cancellable = SettingsService.shared.$showKeepAwakeInMenuBar
            .combineLatest(keepAwake.$isActive, keepAwake.$until)
            .sink { [weak self] shown, active, _ in
                self?.update(shown: shown && !KeepAwakeService.isDisabledByPolicy, active: active)
            }
    }

    private func update(shown: Bool, active: Bool) {
        guard shown else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = self.item ?? makeItem()
        self.item = item
        let icon = NSImage(systemSymbolName: active ? "cup.and.saucer.fill" : "cup.and.saucer",
                           accessibilityDescription: String(localized: "Keep Awake"))
        icon?.isTemplate = true
        item.button?.image = icon
    }

    private func makeItem() -> NSStatusItem {
        // Same length rule as Crisp's own item (see AppDelegate.setupStatusItem).
        let length = SystemLook.isMacOS27OrLater ? NSStatusItem.variableLength : NSStatusItem.squareLength
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = "crisp.keepAwake"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return item
    }

    @objc private func clicked() {
        let keepAwake = KeepAwakeService.shared
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu, let item else {
            keepAwake.setActive(!keepAwake.isActive)
            return
        }
        // Attached for this click only, so a left click keeps toggling.
        item.menu = makeMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let keepAwake = KeepAwakeService.shared
        let menu = NSMenu()
        let title = keepAwake.until.map {
            String(localized: "Keep Awake until \($0.formatted(date: .omitted, time: .shortened))")
        } ?? String(localized: "Keep Awake")
        menu.addItem(.sectionHeader(title: title))
        for duration in KeepAwakeDuration.allCases {
            let entry = NSMenuItem(title: duration.label, action: #selector(pick(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = duration.rawValue
            entry.state = keepAwake.isActive && keepAwake.duration == duration ? .on : .off
            menu.addItem(entry)
        }
        if keepAwake.isActive {
            menu.addItem(.separator())
            let off = NSMenuItem(title: String(localized: "Turn Off"), action: #selector(turnOff), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        }
        return menu
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let duration = KeepAwakeDuration(rawValue: sender.tag) else { return }
        KeepAwakeService.shared.start(duration)
    }

    @objc private func turnOff() {
        KeepAwakeService.shared.setActive(false)
    }
}
