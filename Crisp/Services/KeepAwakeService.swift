import Foundation
import IOKit.pwr_mgt

// ponytail: session-only + prevent-display-sleep only. Persist across launches or add a
// system-only ("let the screen dim") mode if asked; both are a few lines here.
/// Holds an IOKit power assertion that keeps the display (and, implicitly, the system)
/// awake while active. Session-only: not persisted, so a fresh launch starts inactive.
/// The assertion is released automatically when the process exits, so quitting Crisp can
/// never strand the Mac awake.
@MainActor
final class KeepAwakeService: ObservableObject {
    static let shared = KeepAwakeService()
    private init() {}

    @Published private(set) var isActive = false
    private var assertionID: IOPMAssertionID = 0

    /// Prevent display idle sleep (which also blocks system idle sleep) while `on`.
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        if on {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Crisp Keep Awake" as CFString,
                &id)
            guard result == kIOReturnSuccess else { return }
            assertionID = id
            isActive = true
        } else {
            if assertionID != 0 {
                IOPMAssertionRelease(assertionID)
                assertionID = 0
            }
            isActive = false
        }
    }
}
