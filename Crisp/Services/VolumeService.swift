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
    private init() {
        if let stored = UserDefaults.standard.dictionary(forKey: Self.ceilingsKey) {
            volumeCeilings = stored.compactMapValues { ($0 as? Int).map { UInt16(clamping: $0) } }
        }
    }

    private static let log = Logger(subsystem: "com.crisp.app", category: "volume")

    /// DDC max volume per display (usually 100), from the probe read through
    /// DDCVolumeMax.
    private var ddcMax: [CGDirectDisplayID: UInt16] = [:]
    /// Volume to restore on unmute, captured when toggleMute drops to zero.
    private var preMuteVolume: [CGDirectDisplayID: Double] = [:]

    /// UUIDs of displays that have ever answered a 0x62 read. VCP support is a
    /// hardware fact, so remember it: a flaky launch-time probe (the
    /// wedged-read AOC) can miss, and without the memory the feature vanishes.
    private let capableKey = "crisp.volumeCapableDisplays"
    private lazy var rememberedCapable: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: capableKey) ?? [])

    private func rememberCapable(_ uuid: String) {
        guard rememberedCapable.insert(uuid).inserted else { return }
        UserDefaults.standard.set(Array(rememberedCapable), forKey: capableKey)
    }

    /// UUIDs the user forced volume-capable (issue #57): some monitors accept
    /// 0x62 writes but never answer a 0x62 read, so the probe can't prove
    /// support. Forced displays run write-only at the assumed max of 100.
    private let forcedKey = "crisp.volumeForcedDisplays"
    /// Published so the Settings block's Show Volume Sliders row re-checks on
    /// toggle; DisplayInfo.volumeSupported alone only re-renders one card.
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
    /// displayID cannot inherit it. rememberedCapable and volumeCeilings stay:
    /// both are UUID-keyed and deliberately permanent.
    func invalidate(for displayID: CGDirectDisplayID) {
        ddcMax.removeValue(forKey: displayID)
        preMuteVolume.removeValue(forKey: displayID)
    }

    // MARK: - Volume range ceiling

    /// Maximum raw volume per display UUID, set by the DDC Value Range row.
    /// The keyboard's sixteen stops spread over this capped range.
    private static let ceilingsKey = "crisp.volumeMaxOverrides"
    @Published private(set) var volumeCeilings: [String: UInt16] = [:] {
        didSet { UserDefaults.standard.set(volumeCeilings.mapValues(Int.init), forKey: Self.ceilingsKey) }
    }

    /// The display's hardware top from the probe, or the write-only assumption.
    func hardwareMax(for display: DisplayInfo) -> UInt16 {
        ddcMax[display.displayID] ?? 100
    }

    /// The user's ceiling, or nil while the display runs the full hardware range.
    func ceiling(for display: DisplayInfo) -> UInt16? {
        volumeCeilings[display.displayUUID]
    }

    /// The top every write and readback on this display maps onto.
    func effectiveMax(for display: DisplayInfo) -> UInt16 {
        DDCVolumeScale.effectiveMax(hardwareMax: hardwareMax(for: display), ceiling: ceiling(for: display))
    }

    /// Caps the display's volume scale; the hardware top (or nil) restores the
    /// full range. Lowering the ceiling under the monitor's current level drops
    /// it to the ceiling; raising or clearing keeps the raw level and only
    /// rescales the percentage.
    func setCeiling(_ value: UInt16?, for display: DisplayInfo) {
        guard !display.isBuiltin else { return }
        let oldRaw = DDCVolumeScale.raw(fromPercent: display.volume, effectiveMax: effectiveMax(for: display))
        let top = hardwareMax(for: display)
        if let value, Int(value) < Int(top) {
            volumeCeilings[display.displayUUID] = DDCVolumeScale.clampedCeiling(Int(value), hardwareMax: top)
        } else {
            volumeCeilings.removeValue(forKey: display.displayUUID)
        }
        let newMax = effectiveMax(for: display)
        if oldRaw > newMax {
            setVolume(100, for: display)
        } else {
            display.volume = DDCVolumeScale.percent(fromRaw: oldRaw, effectiveMax: newMax)
        }
    }

    // MARK: - Probe

    /// Reads VCP 0x62 once: success marks the display volume-capable and
    /// adopts the monitor's level, failure leaves the feature hidden. Safe to
    /// re-run on every refresh; a monitor answering late heals next pass.
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
                let volumeMax = DDCVolumeMax.from(result.max)
                if !self.rememberedCapable.contains(uuid) {
                    Self.log.notice("\(display.name, privacy: .public): volume probe ok \(result.current, privacy: .public)/\(volumeMax, privacy: .public), slider shown")
                }
                self.ddcMax[id] = volumeMax
                display.volumeSupported = true
                self.rememberCapable(uuid)
                // Adopt the hardware level only while our writer is idle, so a
                // stale cached read never fights an in-flight drag.
                if self.pending[id] == nil, !self.pumpActive.contains(id) {
                    let top = DDCVolumeScale.effectiveMax(
                        hardwareMax: volumeMax,
                        ceiling: self.volumeCeilings[uuid]
                    )
                    display.volume = DDCVolumeScale.percent(fromRaw: result.current, effectiveMax: top)
                }
            }
        }
    }

    // MARK: - Set (coalesced)

    /// Latest pending write per display; only one DDC write in flight each.
    /// The UUID rides along so the write maps onto the display's ceiling.
    private struct PendingWrite {
        let percent: Double
        let uuid: String
    }
    private var pending: [CGDirectDisplayID: PendingWrite] = [:]
    private var pumpActive: Set<CGDirectDisplayID> = []

    /// Sets speaker volume (0–100 of the display's scale). Coalesced like the
    /// brightness writer: latest value wins, writes paced to the MCCS ~50ms
    /// spacing so slider drags don't flood the I2C bus that brightness shares.
    func setVolume(_ percent: Double, for display: DisplayInfo) {
        let clamped = max(0.0, min(100.0, percent))
        display.volume = clamped
        pending[display.displayID] = PendingWrite(percent: clamped, uuid: display.displayUUID)
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
        guard !pumpActive.contains(id), let write = pending.removeValue(forKey: id) else { return }
        pumpActive.insert(id)
        let top = DDCVolumeScale.effectiveMax(
            hardwareMax: ddcMax[id] ?? 100,
            ceiling: volumeCeilings[write.uuid]
        )
        let raw = DDCVolumeScale.raw(fromPercent: write.percent, effectiveMax: top)
        DDCService.shared.writeAsync(displayID: id, command: DDCService.volumeVCP, value: raw) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)  // MCCS write spacing
                self.pumpActive.remove(id)
                self.pump(for: id)
            }
        }
    }

    // MARK: - Volume-key routing

    /// The external display whose speakers own the default audio output, or
    /// nil to pass the keys through untouched. Matches by device name, with a
    /// single-candidate HDMI/DisplayPort fallback when names differ.
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
