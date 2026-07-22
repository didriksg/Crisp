import SwiftUI

@main
struct CrispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar UI is a custom NSStatusItem + NSPanel owned by AppDelegate
        // (MenuBarExtra's window carries a WindowServer zoom-in animation we can't
        // disable). Settings is the only SwiftUI scene and stays unused.
        Settings { EmptyView() }
    }
}
