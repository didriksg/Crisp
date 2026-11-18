import SwiftUI

// The three tabs of the Advanced Settings window (AdvancedSettingsWindowController).
// A setting goes here when Crisp works fully without it: it fixes an unusual monitor,
// tunes a default, or serves scripts and power users (docs/DESIGN.md). A row that does
// not apply on this Mac right now is hidden.

private let tabWidth: CGFloat = 520

// MARK: - General

struct AdvancedGeneralTab: View {
    @ObservedObject private var settings = SettingsService.shared
    @State private var cliInstalled = CrispctlInstaller.isInstalled

    var body: some View {
        let showsSwitches = PhysicalDisplayToggleService.shared.isSupported
        let showsCLI = CrispctlInstaller.isAvailable
        Group {
            if showsSwitches || showsCLI {
                Form {
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

/// The connected external displays as pictures in a row, as System Settings > Displays
/// shows them, and the selected one's settings below. The row scrolls sideways when the
/// displays do not fit, so every name and shape stays whole. Built-in and virtual
/// displays have no advanced setting yet, so they are not listed, and the window shows
/// this tab only while the row is not empty.
struct AdvancedDisplaysTab: View {
    @EnvironmentObject var displayManager: DisplayManager
    @State private var selection: CGDirectDisplayID?

    var body: some View {
        let displays = advancedSettingsDisplays(displayManager.displays)
        let selected = displays.first(where: { $0.displayID == selection }) ?? displays.first
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 20) {
                    ForEach(displays) { display in
                        DisplayPicture(display: display, isSelected: display.displayID == selected?.displayID)
                            .onTapGesture { selection = display.displayID }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(minWidth: tabWidth)  // centred while the row fits
            }
            Divider()
            if let selected {
                AdvancedDisplayPage(display: selected)
            }
        }
        .frame(width: tabWidth)
    }
}

/// One display in the row: its wallpaper in the display's shape, sized by its physical
/// diagonal so a 49-inch display reads larger than a 24-inch one, and its full name.
private struct DisplayPicture: View {
    @ObservedObject var display: DisplayInfo
    let isSelected: Bool
    @State private var wallpaper: NSImage?

    private var size: CGSize {
        let aspect = display.bounds.height > 0 ? display.bounds.width / display.bounds.height : 16.0 / 9
        let millimetres = CGDisplayScreenSize(display.displayID)
        let diagonal = hypot(millimetres.width, millimetres.height)
        // ponytail: 0.17 pt per mm puts a 27-inch 16:9 at about 56 pt tall; no EDID size reads as 27 inch.
        let points = min(max(diagonal > 0 ? diagonal : 686, 400), 1300) * 0.17
        let height = points / (1 + aspect * aspect).squareRoot()
        return CGSize(width: height * aspect, height: height)
    }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let wallpaper {
                    Image(nsImage: wallpaper).resizable().scaledToFill()
                } else {
                    Color(nsColor: .controlBackgroundColor)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.6), lineWidth: 2))
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3).opacity(isSelected ? 1 : 0))
            Text(display.name)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .fixedSize()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .task(id: display.displayID) { wallpaper = await DesktopWallpaper.image(for: display.displayID) }
    }
}

/// The displays the Displays tab lists; also decides whether the tab is shown.
@MainActor
func advancedSettingsDisplays(_ displays: [DisplayInfo]) -> [DisplayInfo] {
    displays.filter { !$0.isBuiltin && !VirtualDisplayService.shared.isVirtualDisplay($0.displayID) }
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
