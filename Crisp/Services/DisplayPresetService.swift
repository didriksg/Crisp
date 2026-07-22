import Foundation
import CoreGraphics

/// Reads and switches display reference-mode presets, the System Settings
/// "Preset" menu shown for XDR builtin panels (Apple XDR Display, HDR Video,
/// Digital Cinema, ...). Uses the private MonitorPanel framework via dlopen +
/// the ObjC runtime, same pattern as the other private-API services.
@MainActor
final class DisplayPresetService: ObservableObject, @unchecked Sendable {
    static let shared = DisplayPresetService()

    struct Preset: Identifiable, Equatable {
        let index: Int
        let name: String
        var id: Int { index }
    }

    /// MPDisplayMgr instance; nil when MonitorPanel is unavailable.
    private let manager: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil,
              let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private init() {}

    private func mpDisplay(for displayID: CGDirectDisplayID) -> NSObject? {
        guard let displays = manager?.value(forKey: "displays") as? [NSObject] else { return nil }
        return displays.first { ($0.value(forKey: "displayID") as? UInt32) == displayID }
    }

    /// Valid presets for the display, in system order. Empty when the display
    /// has no presets (external monitors, older builtin panels).
    func presets(for displayID: CGDirectDisplayID) -> [Preset] {
        guard let d = mpDisplay(for: displayID),
              d.value(forKey: "hasPresets") as? Bool == true,
              let list = d.value(forKey: "presets") as? [NSObject] else { return [] }
        return list.compactMap { p in
            guard p.value(forKey: "isValid") as? Bool == true,
                  let name = p.value(forKey: "presetName") as? String,
                  let index = p.value(forKey: "presetIndex") as? Int else { return nil }
            return Preset(index: index, name: name)
        }
    }

    func activePresetIndex(for displayID: CGDirectDisplayID) -> Int? {
        guard let d = mpDisplay(for: displayID) else { return nil }
        return (d.value(forKey: "activePreset") as? NSObject)?.value(forKey: "presetIndex") as? Int
    }

    @discardableResult
    func setActivePreset(index: Int, for displayID: CGDirectDisplayID) -> Bool {
        guard let d = mpDisplay(for: displayID),
              let list = d.value(forKey: "presets") as? [NSObject],
              let preset = list.first(where: { ($0.value(forKey: "presetIndex") as? Int) == index })
        else { return false }
        _ = d.perform(NSSelectorFromString("setActivePreset:"), with: preset)
        return true
    }
}
