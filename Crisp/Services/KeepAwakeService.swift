import Foundation
import IOKit.pwr_mgt
import SwiftUI

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
    @Published private(set) var duration: KeepAwakeDuration = .indefinite
    @Published private(set) var remainingMinutes: Int?
    private var assertionID: IOPMAssertionID = 0
    private var expirationDate: Date?
    private var timer: Timer?

    /// True when a configuration profile sets `crisp.disableKeepAwake` = true; managed
    /// values outrank the user's own, so a `defaults write` cannot switch it back on.
    /// The Tools row is hidden rather than greyed out. (issue #70)
    static var isDisabledByPolicy: Bool {
        UserDefaults.standard.bool(forKey: "crisp.disableKeepAwake")
    }

    /// Inline subtitle shown on `KeepAwakeRow` when a countdown is running; nil when off or `.indefinite`.
    var rowSubtitle: String? {
        guard isActive, let mins = remainingMinutes, mins > 0 else { return nil }
        return KeepAwakeDuration.countdownLabel(minutes: mins)
    }

    /// Subtitle shown on the collapsed `Tools` header when Keep Awake is active.
    var toolsSubtitle: String? {
        KeepAwakeDuration.toolsSubtitle(isActive: isActive, remainingMinutes: remainingMinutes)
    }

    /// Prevent display idle sleep (which also blocks system idle sleep) while `on`.
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
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
            duration = .indefinite
            cancelTimer()
        } else {
            cancelTimer()
            duration = .indefinite
            if assertionID != 0 {
                IOPMAssertionRelease(assertionID)
                assertionID = 0
            }
            isActive = false
        }
    }

    /// Select a duration (`Always` or a bounded sleep timer), activating Keep Awake if needed.
    func selectDuration(_ newDuration: KeepAwakeDuration) {
        guard !Self.isDisabledByPolicy else { return }
        if !isActive {
            setActive(true)
        }
        guard isActive else { return }
        duration = newDuration
        cancelTimer()
        if let seconds = newDuration.seconds {
            expirationDate = Date().addingTimeInterval(seconds)
            remainingMinutes = KeepAwakeDuration.remainingMinutes(for: seconds)
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// Recompute remaining minutes or expire the assertion when the deadline has passed.
    func refreshRemaining(now: Date = Date()) {
        guard isActive, let exp = expirationDate else { return }
        let rem = exp.timeIntervalSince(now)
        if rem <= 0 {
            withAnimation(.panelResize) {
                setActive(false)
            }
        } else {
            let mins = KeepAwakeDuration.remainingMinutes(for: rem)
            if remainingMinutes != mins {
                remainingMinutes = mins
            }
        }
    }

    private func tick() {
        refreshRemaining()
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
        expirationDate = nil
        remainingMinutes = nil
    }
}
