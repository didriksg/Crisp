import Foundation
import CoreGraphics
import CoreAudio
import AppKit
import os.log

/// DDC/CI speaker volume (VCP 0x62) for external monitors (issue #23):
/// support probing, a coalesced writer, mute, and default-audio-output
/// matching for the volume keys. Mute is modeled as "volume 0 + remembered
/// previous level", which works on every monitor that answers 0x62.
/// ponytail: real VCP 0x8D mute is the upgrade if monitors misbehave on 0.
@MainActor
final class VolumeService: ObservableObject {
    static let shared = VolumeService()
    private init() {}

    private static let log = Logger(subsystem: "com.crisp.app", category: "volume")

    /// Raw DDC max volume per display (usually 100), from the probe read.
    private var ddcMax: [CGDirectDisplayID: UInt16] = [:]
    /// Volume to restore on unmute, captured when toggleMute drops to zero.
    private var preMuteVolume: [CGDirectDisplayID: Double] = [:]

    /// UUIDs of displays that have EVER answered a 0x62 read. VCP support is a
    /// hardware fact, so remember it: on flaky DDC (the wedged-read AOC) a
    /// launch-time probe can miss, and without the memory the slider, the
    /// settings toggle, and the key routing would all vanish for the session.
    private let capableKey = "crisp.volumeCapableDisplays"
    private lazy var rememberedCapable: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: capableKey) ?? [])

    private func rememberCapable(_ uuid: String) {
        guard rememberedCapable.insert(uuid).inserted else { return }
        UserDefaults.standard.set(Array(rememberedCapable), forKey: capableKey)
    }

    /// UUIDs the user forced volume-capable (issue #57). Some monitors (LG
    /// 27UP850N over USB-C) never answer a 0x62 read but do accept 0x62
    /// writes, so the probe can never prove support. Forced displays run
    /// write-only with the assumed max of 100 (the pump's default).
    private let forcedKey = "crisp.volumeForcedDisplays"
    /// Published so the Settings block re-checks whether any display reports
    /// volume when the toggle flips: DisplayInfo.volumeSupported alone only
    /// re-renders the display's own card, and the Show Volume Sliders row
    /// stayed hidden until the display list next changed.
    @Published private var forcedCapable: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "crisp.volumeForcedDisplays") ?? [])

    func isForced(_ display: DisplayInfo) -> Bool {
        forcedCapable.contains(display.displayUUID)
    }

    func setForced(_ on: Bool, for display: DisplayInfo) {
        if on {
            forcedCapable.insert(display.displayUUID)
        } else {
            forcedCapable.remove(display.displayUUID)
        }
        UserDefaults.standard.set(Array(forcedCapable), forKey: forcedKey)
        // Un-forcing keeps the feature only if a real probe ever succeeded.
        display.volumeSupported = on || rememberedCapable.contains(display.displayUUID)
    }

    /// Drop per-display state for a disconnected display so a reused
    /// displayID cannot inherit it. rememberedCapable stays: it is UUID-keyed
    /// and deliberately permanent.
    func invalidate(for displayID: CGDirectDisplayID) {
        ddcMax.removeValue(forKey: displayID)
        preMuteVolume.removeValue(forKey: displayID)
    }

    // MARK: - Probe

    /// Reads VCP 0x62 once. Success marks the display volume-capable (the
    /// slider appears, keys route) and adopts the monitor's current level;
    /// failure leaves the feature hidden. Safe to re-run on every display
    /// refresh: a monitor that answers late (link training) heals on the
    /// next pass, and DDCService caches reads for 5s.
    func refreshVolume(for display: DisplayInfo) {
        guard !display.isBuiltin else { return }
        // Seed from memory (or the user's force override) so a failed probe
        // can't hide the feature; the read below still adopts the monitor's
        // current level whenever it works.
        if rememberedCapable.contains(display.displayUUID) || forcedCapable.contains(display.displayUUID) {
            display.volumeSupported = true
        }
        let id = display.displayID
        let uuid = display.displayUUID
        DDCService.shared.readAsync(displayID: id, command: DDCService.volumeVCP) { result in
            Task { @MainActor in
                guard let result else {
                    // Only while the feature is hidden: a remembered or forced
                    // display failing a probe is the DDC layer's line to log.
                    if !display.volumeSupported {
                        Self.log.notice("\(display.name, privacy: .public): volume probe (VCP 0x62) got no valid reply, slider hidden; the Volume Control toggle forces write-only")
                    }
                    return
                }
                if !self.rememberedCapable.contains(uuid) {
                    Self.log.notice("\(display.name, privacy: .public): volume probe ok \(result.current, privacy: .public)/\(result.max, privacy: .public), slider shown")
                }
                self.ddcMax[id] = result.max
                display.volumeSupported = true
                self.rememberCapable(uuid)
                // Adopt the hardware level only while our writer is idle, so a
                // stale cached read never fights an in-flight drag.
                if self.pending[id] == nil, !self.pumpActive.contains(id) {
                    display.volume = Double(result.current) / Double(result.max) * 100.0
                }
            }
        }
    }

    // MARK: - Set (coalesced)

    /// Latest pending percent per display; only one DDC write in flight each.
    private var pending: [CGDirectDisplayID: Double] = [:]
    private var pumpActive: Set<CGDirectDisplayID> = []

    /// Sets speaker volume (0–100). Coalesced like the brightness writer:
    /// latest value wins, writes paced to the MCCS ~50ms spacing so slider
    /// drags don't flood the I2C bus that brightness shares.
    func setVolume(_ percent: Double, for display: DisplayInfo) {
        let clamped = max(0.0, min(100.0, percent))
        display.volume = clamped
        pending[display.displayID] = clamped
        pump(for: display.displayID)
    }

    /// Mute key behavior: at zero, restore the remembered pre-mute level (or
    /// 25 if there is none); otherwise remember the level and drop to zero.
    func toggleMute(for display: DisplayInfo) {
        if display.volume <= 0 {
            setVolume(preMuteVolume[display.displayID] ?? 25, for: display)
        } else {
            preMuteVolume[display.displayID] = display.volume
            setVolume(0, for: display)
        }
    }

    private func pump(for id: CGDirectDisplayID) {
        guard !pumpActive.contains(id), let percent = pending.removeValue(forKey: id) else { return }
        pumpActive.insert(id)
        let raw = UInt16((percent / 100.0 * Double(ddcMax[id] ?? 100)).rounded())
        DDCService.shared.writeAsync(displayID: id, command: DDCService.volumeVCP, value: raw) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)  // MCCS write spacing
                self.pumpActive.remove(id)
                self.pump(for: id)
            }
        }
    }

    // MARK: - Volume-key routing

    /// The external display whose speakers own the current default audio
    /// output, or nil when audio goes elsewhere (the keys then pass through
    /// to macOS untouched). Matches the audio device name against the display
    /// name, with a single-candidate fallback for HDMI/DisplayPort transports
    /// whose device name differs from the display name.
    /// ponytail: name + transport matching; per-display audio binding UI if
    /// same-model multi-monitor setups misroute.
    func displayForDefaultAudioOutput(in displays: [DisplayInfo]) -> DisplayInfo? {
        let candidates = displays.filter { !$0.isBuiltin && $0.volumeSupported }
        guard !candidates.isEmpty else { return nil }

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }

        if let name = audioDeviceName(deviceID),
           let byName = candidates.first(where: { $0.name == name }) {
            return byName
        }
        if candidates.count == 1, let transport = audioTransportType(deviceID),
           transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort {
            return candidates[0]
        }
        return nil
    }

    private func audioDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func audioTransportType(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }
}
