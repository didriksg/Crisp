import SwiftUI
import CoreGraphics

// DisplayServices private framework, the macOS "Automatically adjust brightness"
// (ambient light compensation) setting, same dlopen already used by BrightnessService.
// See supported() below for what counts as unsupported.
private let _DSAmbientEnabled: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<UInt8>) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesAmbientLightCompensationEnabled") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<UInt8>) -> Int32).self)
}()
private let _DSAmbientSet: (@convention(c) (CGDirectDisplayID, UInt8) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesEnableAmbientLightCompensation") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UInt8) -> Int32).self)
}()

enum SystemAutoBrightness {
    /// Supported only where the OS ambient-light auto-brightness applies (built-in and
    /// ALS-equipped panels like Studio Display). The getter returns 0 there and an error
    /// on sensor-less externals, so its success IS the support check, no model guessing.
    static func supported(_ id: CGDirectDisplayID) -> Bool {
        guard let get = _DSAmbientEnabled else { return false }
        var on: UInt8 = 0
        return get(id, &on) == 0
    }
    static func isEnabled(_ id: CGDirectDisplayID) -> Bool {
        guard let get = _DSAmbientEnabled else { return false }
        var on: UInt8 = 0
        return get(id, &on) == 0 && on != 0
    }
    static func setEnabled(_ id: CGDirectDisplayID, _ on: Bool) {
        _ = _DSAmbientSet?(id, on ? 1 : 0)
    }
}

/// Toggle for macOS "Automatically adjust brightness" (ambient light) on this display.
/// Placed by subject: the setting adjusts *this* panel, so it lives under the built-in
/// display, mirroring System Settings. Absent on sensor-less externals (see supported()).
struct SystemAutoBrightnessView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isOn = false
    @State private var isHovered = false

    // Read the live OS value. Called on appear and on every panel open: the panel
    // content mounts once (onAppear can't re-fire) and the user can flip this in
    // System Settings while Crisp is closed, so a one-time read would go stale.
    private func sync() { isOn = SystemAutoBrightness.isEnabled(display.displayID) }

    var body: some View {
        if SystemAutoBrightness.supported(display.displayID) {
            HStack {
                MenuItemIcon(systemName: "sun.max", color: .yellow, active: isOn)
                Text("Automatically adjust brightness")
                    .font(.body)
                Spacer()
                // Custom binding so a programmatic sync() only moves the switch; the
                // setter writes to the OS solely on real user interaction.
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        isOn = newValue
                        SystemAutoBrightness.setEnabled(display.displayID, newValue)
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(isHovered)
            .onHover { isHovered = $0 }
            .onAppear { sync() }
            .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in sync() }
        }
    }
}
