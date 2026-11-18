import SwiftUI

// The three tabs of the Advanced Settings window (AdvancedSettingsWindowController).
// A setting goes here when Crisp works fully without it: it fixes an unusual monitor,
// tunes a default, or serves scripts and power users (docs/DESIGN.md). A row that does
// not apply on this Mac right now is hidden.

private let tabWidth: CGFloat = 520

// MARK: - General

struct AdvancedGeneralTab: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var autoBrightness = AutoBrightnessService.shared
    @EnvironmentObject var displayManager: DisplayManager
    @State private var cliInstalled = CrispctlInstaller.isInstalled

    private var physicalDisplays: [DisplayInfo] {
        displayManager.displays.filter { !VirtualDisplayService.shared.isVirtualDisplay($0.displayID) }
    }

    /// The ratio relates the built-in to the externals, so it needs both to be on.
    private var hasBuiltinAndExternal: Bool {
        physicalDisplays.contains(where: { $0.isBuiltin }) && physicalDisplays.contains(where: { !$0.isBuiltin })
    }

    /// Auto Brightness follows the built-in's own brightness, so a Mac without one has none.
    private var hasBuiltin: Bool {
        !(autoBrightness.hasPolled && autoBrightness.builtinBrightness <= 0)
    }

    /// The slider's own value: 100% is Crisp's match from the rated nits. The effective
    /// ratio (external nits / built-in nits x this) read as a second, unrelated number.
    private var ratioPercent: Int {
        Int((settings.combinedBuiltinBrightnessFactor * 100).rounded())
    }

    var body: some View {
        let showsSwitches = PhysicalDisplayToggleService.shared.isSupported
        // No built-in panel to turn off on a Mac with no battery (a disconnected built-in
        // leaves the display list, so the battery is the laptop test), nor on Intel.
        let showsAutoDisconnect = showsSwitches && PhysicalDisplayToggleService.hasBattery
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        if newValue { LaunchService.shared.enable() } else { LaunchService.shared.disable() }
                        settings.launchAtLogin = LaunchService.shared.isEnabled
                    }
                ))
            }
            Section("Brightness") {
                if hasBuiltin {
                    Toggle(isOn: $autoBrightness.isEnabled) {
                        Text("Auto Brightness")
                        Text("External displays follow the built-in display's brightness")
                    }
                    if autoBrightness.isEnabled {
                        Toggle(isOn: $autoBrightness.relativeMode) {
                            Text("Keep display offsets")
                            Text("External displays follow the built-in but keep the difference you set")
                        }
                    }
                }
                Toggle("Show Combined Brightness", isOn: $settings.showCombinedBrightness)
                if settings.showCombinedBrightness && hasBuiltinAndExternal {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Absolute brightness ratio")
                            Spacer()
                            Text("\(ratioPercent)%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.combinedBuiltinBrightnessFactor,
                            in: CombinedBrightnessMath.builtinAdjustmentRange
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
            if showsAutoDisconnect {
                Section("Displays") {
                    Toggle(isOn: $settings.disconnectBuiltinWhenDocked) {
                        Text("Auto-Disconnect Built-in")
                        Text("Turns the built-in display off while an external display is connected")
                    }
                    .onChange(of: settings.disconnectBuiltinWhenDocked) { _, isOn in
                        if isOn {
                            PhysicalDisplayToggleService.shared.reapplyParkedIfDocked()
                        } else {
                            PhysicalDisplayToggleService.shared.clearParked()
                        }
                    }
                }
            }
            Section("Menu Bar") {
                // Hiding the sliders does not disable the volume keys.
                Toggle("Show Volume Sliders", isOn: $settings.showVolumeSliders)
                if showsSwitches {
                    Toggle(isOn: $settings.showConnectionSwitches) {
                        Text("Show Connection Switches")
                        Text("A switch on each display row that disconnects it")
                    }
                }
            }
            if CrispctlInstaller.isAvailable {
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
        .onAppear {
            cliInstalled = CrispctlInstaller.isInstalled
            settings.launchAtLogin = LaunchService.shared.isEnabled  // may change in System Settings
        }
        .frame(width: tabWidth)
    }
}

// MARK: - Keyboard

/// The curated global-shortcut actions (issues #61, #160, #23). Per-preset shortcuts
/// live on the presets in the panel, not here.
struct AdvancedKeyboardTab: View {
    @ObservedObject private var settings = SettingsService.shared
    @EnvironmentObject var displayManager: DisplayManager
    // Until Accessibility is granted the section asks for it (the panel asks too, so people
    // who never open this window are asked); then it picks which displays the keys adjust.
    // AXIsProcessTrusted() is not observable, so it is re-read when Crisp becomes active.
    @State private var isTrusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                if isTrusted {
                    Picker("Brightness Keys", selection: $settings.brightnessKeyTarget) {
                        ForEach(BrightnessKeyTarget.allCases, id: \.self) { Text(targetName($0)).tag($0) }
                    }
                    // Keyed by displayUUID so the choice survives reconnects.
                    if settings.brightnessKeyTarget == .selected {
                        ForEach(displayManager.displays) { display in
                            Toggle(display.name, isOn: Binding(
                                get: { settings.brightnessKeySelectedDisplayUUIDs.contains(display.displayUUID) },
                                set: { isOn in
                                    if isOn {
                                        settings.brightnessKeySelectedDisplayUUIDs.insert(display.displayUUID)
                                    } else {
                                        settings.brightnessKeySelectedDisplayUUIDs.remove(display.displayUUID)
                                    }
                                }
                            ))
                        }
                    }
                } else {
                    // Also in the panel, which is where most people meet it.
                    Toggle(isOn: Binding(
                        get: { false },
                        set: { if $0 { BrightnessKeyService.requestAccess() } }
                    )) {
                        Text("Use brightness keys on external displays")
                        // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                        Text("Brightness keys need Accessibility access to redirect them to external displays. Grant it once and they start working, no restart.")
                    }
                }
            }
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
        .onAppear { isTrusted = AXIsProcessTrusted() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = AXIsProcessTrusted()
        }
        .frame(width: tabWidth)
    }

    private func targetName(_ target: BrightnessKeyTarget) -> String {
        switch target {
        case .underCursor: return String(localized: "Follow the pointer")
        case .allDisplays: return String(localized: "All connected displays")
        case .selected:    return String(localized: "Selected displays only")
        }
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

/// The connected displays as pictures in a row, as System Settings > Displays shows them,
/// and the selected one's settings below. The row scrolls sideways when the displays do
/// not fit, so every name and shape stays whole. Virtual displays have their own tab.
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
                AdvancedDisplayPage(display: selected, displayManager: displayManager)
                    .id(selected.displayID)  // fresh controllers per display
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

/// The displays the Displays tab lists (every one but Crisp's virtual displays); also
/// decides whether the tab is shown.
@MainActor
func advancedSettingsDisplays(_ displays: [DisplayInfo]) -> [DisplayInfo] {
    displays.filter { !VirtualDisplayService.shared.isVirtualDisplay($0.displayID) }
}

/// The settings of one display, grouped by topic as System Settings > Displays groups
/// them. The card in the panel repeats the ones changed often; a row only in this window
/// sits in its topic's section like any other (Volume Control). Panel only: actions (the
/// sliders, Disconnect, input switching, applying a preset) and settings that belong with
/// a panel control (Smooth Scaling with the resolution slider, Image Adjustment).
private struct AdvancedDisplayPage: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @StateObject private var modes: DisplayModeController
    @StateObject private var color: DisplayProfileController
    @State private var profiles: [ICCProfile] = []
    @State private var profilePath: URL?
    @State private var errorText: String?

    init(display: DisplayInfo, displayManager: DisplayManager) {
        self.display = display
        _modes = StateObject(wrappedValue: DisplayModeController(display: display, displayManager: displayManager))
        _color = StateObject(wrappedValue: DisplayProfileController(display: display))
    }

    var body: some View {
        Form {
            Section {
                resolutionPicker
                if let group = modes.currentGroup, group.hasMultipleRates {
                    Picker("Refresh Rate", selection: Binding(
                        get: { modes.currentMode?.id ?? 0 },
                        set: { id in if let mode = group.modes.first(where: { $0.id == id }) { modes.selectRefresh(mode) } }
                    )) {
                        ForEach(group.modes) { Text(verbatim: modes.refreshLabel($0)).tag($0.id) }
                    }
                }
                NotchView(display: display, inForm: true)
                if let message = modes.errorMessage ?? errorText {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Color") {
                if !color.presetName.isEmpty {
                    Picker("Preset", selection: Binding(
                        get: { color.activePresetIndex ?? -1 },
                        set: { index in
                            if DisplayPresetService.shared.setActivePreset(index: index, for: display.displayID) {
                                color.reload()
                            }
                        }
                    )) {
                        ForEach(color.presets, id: \.index) { Text(verbatim: $0.name).tag($0.index) }
                    }
                } else {
                    Picker("Color Profile", selection: Binding(
                        get: { profilePath },
                        set: { path in
                            guard let profile = profiles.first(where: { $0.path == path }) else { return }
                            if ColorProfileService.shared.setProfile(profile, for: display.displayID) {
                                profilePath = path
                            } else {
                                showError(String(localized: "Failed to apply. Please try again."))
                            }
                        }
                    )) {
                        ForEach(profiles, id: \.path) { Text(verbatim: $0.name).tag(Optional($0.path)) }
                    }
                    .task { await loadProfiles() }
                }
                HDRToggleView(display: display, inForm: true)
            }
            if BrightnessBoostService.shared.isEligible(display) || SystemAutoBrightness.supported(display.displayID) {
                Section("Brightness") {
                    ExtraBrightnessView(display: display, inForm: true)
                    SystemAutoBrightnessView(display: display, inForm: true)
                }
            }
            Section("Connection") {
                // A display stops being main only when another one becomes main.
                Toggle("Main Display", isOn: Binding(get: { display.isMain }, set: { if $0 { makeMain() } }))
                    .disabled(display.isMain)
                if !display.isBuiltin {
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
        }
        .formStyle(.grouped)
        .onAppear { color.reload() }
    }

    /// The panel's split: the native size first, then HiDPI and Non-HiDPI sizes.
    private var resolutionPicker: some View {
        let groups = modes.resolutionGroups
        return Picker("Resolution", selection: Binding(
            get: { modes.currentGroup?.id ?? "" },
            set: { id in if let group = groups.first(where: { $0.id == id }) { modes.selectResolution(group) } }
        )) {
            ForEach(groups.filter(\.isDefault)) { Text(verbatim: $0.menuLabel).tag($0.id) }
            Section("HiDPI") {
                ForEach(groups.filter { $0.isHiDPI && !$0.isDefault }) { Text(verbatim: $0.resolutionString).tag($0.id) }
            }
            Section("Non-HiDPI") {
                ForEach(groups.filter { !$0.isHiDPI && !$0.isDefault }) { Text(verbatim: $0.menuLabel).tag($0.id) }
            }
        }
    }

    private func loadProfiles() async {
        let loaded = await ColorProfileService.shared.enumerateProfiles(for: display.displayUUID)
        let current = ColorProfileService.shared.currentProfileURL(for: display.displayID)
        profiles = loaded
        // Match by path: the registry URL and FileManager's can differ in percent-encoding.
        profilePath = loaded.first(where: { $0.path.path == current?.path })?.path ?? current
    }

    private func makeMain() {
        Task { @MainActor in
            if !(await ArrangementService.shared.setAsMainDisplay(display.displayID, among: displayManager.displays)) {
                showError(String(localized: "Failed to set main display"))
            }
        }
    }

    private func showError(_ text: String) {
        errorText = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            errorText = nil
        }
    }
}
