import Foundation
import IOKit.pwr_mgt

// ponytail: session-only + prevent-display-sleep only. Persist across launches or add a
// system-only ("let the screen dim") mode if asked; both are a few lines here.
/// Holds an IOKit power assertion that keeps the display (and, implicitly, the system)
/// awake while active. Session-only; the assertion releases automatically on exit, so
/// quitting Crisp can never strand the Mac awake.
@MainActor
final class KeepAwakeService: ObservableObject {
    static let shared = KeepAwakeService()
    private init() {}

    @Published private(set) var isActive = false
    /// The chosen limit while active; the switch alone gives `untilTurnedOff`.
    @Published private(set) var duration = KeepAwakeDuration.untilTurnedOff
    /// When a time limit ends; nil with no limit.
    @Published private(set) var until: Date?
    private var assertionID: IOPMAssertionID = 0
    private var expiry: Timer?

    /// True when a configuration profile sets `crisp.disableKeepAwake` = true; managed
    /// values outrank the user's own, so a `defaults write` cannot switch it back on.
    /// The Tools row is hidden rather than greyed out. (issue #70)
    static var isDisabledByPolicy: Bool {
        UserDefaults.standard.bool(forKey: "crisp.disableKeepAwake")
    }

    /// Prevent display idle sleep (which also blocks system idle sleep) while `on`.
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        clearLimit()
        if on {
            guard !Self.isDisabledByPolicy else { return }
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

    /// Turns Keep Awake on if needed, with `duration` as its limit. One timer at the end
    /// time, no ticking: the row shows the end time, not a countdown.
    func start(_ duration: KeepAwakeDuration) {
        setActive(true)
        guard isActive else { return }
        clearLimit()
        self.duration = duration
        guard let seconds = duration.seconds else { return }
        let end = Date().addingTimeInterval(seconds)
        until = end
        // A fire date, not an interval, so a Mac that slept past the end time turns it off at wake.
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.setActive(false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }

    private func clearLimit() {
        expiry?.invalidate()
        expiry = nil
        until = nil
        duration = .untilTurnedOff
    }
}
