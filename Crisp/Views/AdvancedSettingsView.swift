import SwiftUI

// The three tabs of the Advanced Settings window (AdvancedSettingsWindowController).
// A setting goes here when Crisp works fully without it: it fixes an unusual monitor,
// tunes a default, or serves scripts and power users (docs/DESIGN.md).

private let tabWidth: CGFloat = 520

// MARK: - General

struct AdvancedGeneralTab: View {
    @ObservedObject private var settings = SettingsService.shared
    @EnvironmentObject var displayManager: DisplayManager
    @State private var cliInstalled = CrispctlInstaller.isInstalled

    private var physicalDisplays: [DisplayInfo] {
        displayManager.displays.filter { !VirtualDisplayService.shared.isVirtualDisplay($0.displayID) }
    }

    /// The ratio tunes the combined slider, so it shows only while that slider can.
    private var showsRatio: Bool {
        physicalDisplays.count > 1 && settings.showCombinedBrightness
            && physicalDisplays.contains(where: { $0.isBuiltin })
    }

    /// Effective linear-brightness slope: external peak nits divided by the
    /// built-in SDR peak, then multiplied by the user's fine tuning.
    private var combinedBuiltinLuminanceRatio: Double? {
        guard let builtinMax = physicalDisplays.first(where: { $0.isBuiltin })?.nominalMaxNits else {
            return nil
        }
        let externalMaxima = physicalDisplays.filter { !$0.isBuiltin }.compactMap(\.nominalMaxNits)
        guard !externalMaxima.isEmpty else { return nil }
        let externalMax = externalMaxima.reduce(0, +) / Double(externalMaxima.count)
        return externalMax / builtinMax * settings.combinedBuiltinBrightnessFactor
    }

    private var ratioPercent: Int {
        Int(((combinedBuiltinLuminanceRatio ?? settings.combinedBuiltinBrightnessFactor) * 100).rounded())
    }

    var body: some View {
        let showsSwitches = PhysicalDisplayToggleService.shared.isSupported
        let showsCLI = CrispctlInstaller.isAvailable
        Group {
            if showsRatio || showsSwitches || showsCLI {
                Form {
                    if showsRatio {
                        Section("Brightness") {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Absolute brightness ratio")
                                    Spacer()
                                    Text("\(ratioPercent)%").monospacedDigit().foregroundStyle(.secondary)
                                }
                                Slider(
                                    value: $settings.combinedBuiltinBrightnessFactor,
                                    in: CombinedBrightnessMath.builtinAdjustmentRange,
                                    step: 0.02
                                )
                                .accessibilityLabel("Absolute brightness ratio")
                                .accessibilityValue("\(ratioPercent)%")
                                Text("From each panel's rated nits. HDR monitors report their HDR peak, "
                                     + "so lower this if the built-in runs too bright")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if showsSwitches {
                        Section("Menu Bar") {
                            Toggle(isOn: $settings.showConnectionSwitches) {
                                Text("Show Connection Switches")
                                Text("A switch on each display row that disconnects it")
                            }
                        }
                    }
                    if showsCLI {
                        Section("Automation") {
                            Toggle(isOn: Binding(
                                get: { cliInstalled },
                                set: { newValue in
                                    if newValue { CrispctlInstaller.install() } else { CrispctlInstaller.uninstall() }
                                    cliInstalled = CrispctlInstaller.isInstalled
                                }
                            )) {
                                Text("Command Line Tool")
                                Text("Links crispctl into /usr/local/bin")
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .onAppear { cliInstalled = CrispctlInstaller.isInstalled }
            } else {
                emptyState("No advanced settings on this Mac.")
            }
        }
        .frame(width: tabWidth)
    }
}

// MARK: - Keyboard

/// The curated global-shortcut actions (issues #61, #160, #23). Per-preset shortcuts
/// live on the presets in the panel, not here.
struct AdvancedKeyboardTab: View {
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                recorder("Toggle HiDPI", \.hidpiShortcut) { settings.hidpiShortcut = $0 }
                caption("Switches the display under the pointer between HiDPI and low resolution.")
                recorder("Brightness Up", \.brightnessUpShortcut) { settings.brightnessUpShortcut = $0 }
                recorder("Brightness Down", \.brightnessDownShortcut) { settings.brightnessDownShortcut = $0 }
                caption("Steps brightness like the brightness keys, on the same displays. For keyboards without them.")
                recorder("Volume Up", \.volumeUpShortcut) { settings.volumeUpShortcut = $0 }
                recorder("Volume Down", \.volumeDownShortcut) { settings.volumeDownShortcut = $0 }
                recorder("Mute", \.muteShortcut) { settings.muteShortcut = $0 }
                caption("Presses the volume keys for the selected sound output. Needs Accessibility, like the brightness keys.")
            }
        }
        .formStyle(.grouped)
        .frame(width: tabWidth)
    }

    /// Commits at once (no form to save): store, take the combo off whatever else held
    /// it, re-register.
    private func recorder(_ label: String, _ path: KeyPath<SettingsService, KeyboardShortcut?>,
                          assign: @escaping (KeyboardShortcut?) -> Void) -> some View {
        ShortcutRecorderRow(
            label: label,
            shortcut: Binding(
                get: { settings[keyPath: path] },
                set: { newValue in settings.assignStaticShortcut(newValue, assign: assign) }
            ),
            stopsOnPanelClose: false
        )
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Displays

/// One page per connected external display. Built-in and virtual displays have no
/// advanced setting yet, so they are not listed.
struct AdvancedDisplaysTab: View {
    @EnvironmentObject var displayManager: DisplayManager
    @State private var selection: CGDirectDisplayID?

    private var displays: [DisplayInfo] {
        displayManager.displays.filter {
            !$0.isBuiltin && !VirtualDisplayService.shared.isVirtualDisplay($0.displayID)
        }
    }

    var body: some View {
        Group {
            if let first = displays.first {
                let selected = displays.first(where: { $0.displayID == selection }) ?? first
                HStack(spacing: 0) {
                    List(displays, selection: $selection) { display in
                        Label(display.name, systemImage: "display").tag(display.displayID)
                    }
                    .listStyle(.sidebar)
                    .frame(width: 190)
                    Divider()
                    AdvancedDisplayPage(display: selected)
                }
                .onAppear { if selection == nil { selection = first.displayID } }
            } else {
                emptyState("Connect an external display to see its settings.")
            }
        }
        .frame(width: tabWidth + 100, height: 260)
    }
}

private struct AdvancedDisplayPage: View {
    @ObservedObject var display: DisplayInfo

    var body: some View {
        Form {
            Section("Monitor Control") {
                // On for a monitor that never answers the 0x62 probe read forces write-only
                // volume (#57); off stops volume commands to a monitor whose DDC stops after
                // repeated volume writes (#245). Shown whatever Show Volume Sliders says:
                // the volume keys use DDC volume also with the sliders hidden.
                Toggle(isOn: Binding(
                    get: { display.volumeSupported },
                    set: { VolumeService.shared.setEnabled($0, for: display) }
                )) {
                    Text("Volume Control")
                    Text("Speaker volume over DDC. Turn it off if the monitor stops answering, or on if it doesn't report volume.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private func emptyState(_ text: LocalizedStringKey) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 160)
}
