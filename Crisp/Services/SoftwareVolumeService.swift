import AppKit
import CoreAudio

/// Explicit consent only. No persisted enable flag and no wake/reconnect restart.
@available(macOS 14.2, *)
@MainActor
final class SoftwareVolumeService: ObservableObject {
    static let shared = SoftwareVolumeService()
    private var engine: SoftwareVolumeEngine?
    @Published private var display: DisplayInfo?
    var canEnable: Bool { display == nil }
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var stopping = false
    private var cancelledStart = false

    private init() {}

    func enable(for target: DisplayInfo) async {
        guard display == nil, !target.softwareVolumeBusy else { return }
        display = target
        cancelledStart = false
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Self.shared.stop() }
        }
        target.softwareVolumeBusy = true
        target.softwareVolumeStatus = String(localized: "Starting software volume…")
        let volume = VolumeService.shared
        guard await volume.reserveSoftware(for: target) else {
            clearStarting()
            target.softwareVolumeBusy = false
            target.softwareVolumeStatus = String(localized: "Hardware volume is still busy. Try again.")
            return
        }
        guard !cancelledStart, let device = volume.softwareOutput(for: target) else {
            clearStarting()
            volume.releaseSoftware(for: target)
            target.softwareVolumeBusy = false
            target.softwareVolumeStatus = String(localized: "Select this display as the audio output. A unique display name is required.")
            return
        }
        let backend = SoftwareVolumeEngine()
        engine = backend
        do {
            try backend.startDevice(device)
            target.volume = 25
            target.softwareVolumeActive = true
            target.softwareVolumeBusy = false
            target.softwareVolumeStatus = String(localized: "Active · software gain")
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let engine = Self.shared.engine, engine.isHealthy(), target.isOnline,
                          volume.softwareOutput(for: target) != nil else {
                        Self.shared.stop(message: String(localized: "Software volume stopped: output or format changed."))
                        return
                    }
                }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        } catch {
            stop(message: String(localized: """
                 Cannot start software volume. Use stereo 48 kHz output and allow System Audio Recording in System Settings.
                 """)
                 + " (\(error.localizedDescription))")
        }
    }

    private func clearStarting() {
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        display = nil
    }

    func setVolume(_ percent: Double, for target: DisplayInfo) -> Bool {
        guard SoftwareVolumePolicy.usesSoftware(selectedID: display?.displayID, displayID: target.displayID,
                                               active: target.softwareVolumeActive,
                                               routeMatches: VolumeService.shared.softwareOutput(for: target) != nil),
              let engine, engine.isHealthy() else {
            if target.softwareVolumeActive { stop() }
            return false
        }
        engine.setGain(SoftwareVolumePolicy.gain(percent))
        target.volume = Double(SoftwareVolumePolicy.gain(percent)) * 100
        return true
    }

    func stop(message: String? = nil) {
        guard let target = display, !stopping else { return }
        guard let engine else { cancelledStart = true; return }
        stopping = true
        timer?.invalidate()
        timer = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        target.softwareVolumeActive = false
        target.softwareVolumeBusy = true
        target.softwareVolumeStatus = message ?? String(localized: "Stopping software volume…")
        let stopped = engine.stop() // Synchronous callback retirement, including the quit path.
        Task { @MainActor in
            // HAL object lists settle asynchronously. Require two spaced absent observations;
            // never reissue destroys or report cleanup from one immediate list snapshot.
            var absent = 0
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                absent = stopped && engine.objectsGone() ? absent + 1 : 0
                if absent >= 2 { break }
            }
            target.softwareVolumeBusy = false
            if absent >= 2 {
                self.engine = nil
                self.display = nil
                self.stopping = false
                VolumeService.shared.releaseSoftware(for: target)
                target.softwareVolumeStatus = message ?? String(localized: "Off · original audio restored")
            } else {
                target.softwareVolumeBusy = true
                // Keep the engine/lease retained; no DDC routing or second start on unknown cleanup.
                target.softwareVolumeStatus = String(localized: """
                    Software volume is off; cleanup could not be verified. Quit Crisp before trying again.
                    """)
            }
        }
    }
}
