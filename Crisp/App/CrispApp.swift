import SwiftUI

@main
struct CrispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar UI is a custom NSStatusItem + NSPanel owned by AppDelegate
        // (MenuBarExtra's window carries a WindowServer zoom-in animation we can't
        // disable). The App body needs a scene, so the empty Settings scene stays; its
        // Cmd-, menu item is removed, because the panel row is the only way into the
        // Advanced Settings window (AdvancedSettingsWindowController).
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}
