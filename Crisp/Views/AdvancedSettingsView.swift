import SwiftUI

// The three tabs of the Advanced Settings window (AdvancedSettingsWindowController).
// A setting goes here when Crisp works fully without it: it fixes an unusual monitor,
// tunes a default, or serves scripts and power users (docs/DESIGN.md). A row that does
// not apply on this Mac right now is hidden.

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
    /// Still shown while on, so it can be turned off. From the display list: the service's
    /// own read exists only once tracking runs.
    private var showsAutoBrightness: Bool {
        physicalDisplays.contains(where: { $0.isBuiltin }) || autoBrightness.isEnabled
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
                if showsAutoBrightness {
                    CenteredToggle(title: "Auto Brightness",
                                   detail: Text("External displays follow the built-in display's brightness"),
                                   isOn: $autoBrightness.isEnabled)
                    if autoBrightness.isEnabled {
                        CenteredToggle(title: "Keep display offsets",
                                       detail: Text("External displays follow the built-in but keep the difference you set"),
                                       isOn: $autoBrightness.relativeMode)
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
                    CenteredToggle(title: "Auto-Disconnect Built-in",
                                   detail: Text("Turns the built-in display off while an external display is connected"),
                                   isOn: $settings.disconnectBuiltinWhenDocked)
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
                    CenteredToggle(title: "Show Connection Switches",
                                   detail: Text("A switch on each display row that disconnects it"),
                                   isOn: $settings.showConnectionSwitches)
                }
            }
            if CrispctlInstaller.isAvailable {
                Section("Automation") {
                    CenteredToggle(title: "Command Line Tool", detail: Text("Links crispctl into /usr/local/bin"), isOn: Binding(
                        get: { cliInstalled },
                        set: { newValue in
                            if newValue { CrispctlInstaller.install() } else { CrispctlInstaller.uninstall() }
                            cliInstalled = CrispctlInstaller.isInstalled
                        }
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)  // the window's scroll view scrolls; this one took the wheel
        .onAppear {
            cliInstalled = CrispctlInstaller.isInstalled
            settings.launchAtLogin = LaunchService.shared.isEnabled  // may change in System Settings
        }
        .frame(maxWidth: .infinity)  // the window sets the width, scroll bar included
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
                    CenteredToggle(
                        title: "Use brightness keys on external displays",
                        // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                        detail: Text("Brightness keys need Accessibility access to redirect them to external displays. Grant it once and they start working, no restart."),
                        isOn: Binding(get: { false }, set: { if $0 { BrightnessKeyService.requestAccess() } })
                    )
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
        .scrollDisabled(true)  // the window's scroll view scrolls; this one took the wheel
        .onAppear { isTrusted = AXIsProcessTrusted() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = AXIsProcessTrusted()
        }
        .frame(maxWidth: .infinity)  // the window sets the width, scroll bar included
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
            let pictures = HStack(alignment: .bottom, spacing: 20) {
                ForEach(displays) { display in
                    DisplayPicture(display: display, isSelected: display.displayID == selected?.displayID)
                        .onTapGesture { selection = display.displayID }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            // Centred while the row fits, scrolled when it does not.
            ViewThatFits(in: .horizontal) {
                pictures.frame(maxWidth: .infinity)
                ScrollView(.horizontal) { pictures }
            }
            Divider()
            if let selected {
                AdvancedDisplayPage(display: selected, displayManager: displayManager)
                    .id(selected.displayID)  // fresh controllers per display
            }
        }
        .frame(maxWidth: .infinity)  // the window sets the width, scroll bar included
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
/// sits in its topic's section like any other (Volume Control). Panel only: applying a
/// preset, the volume slider, and settings that belong with a panel control (Smooth
/// Scaling with the resolution slider, Image Adjustment).
private struct AdvancedDisplayPage: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @StateObject private var modes: DisplayModeController
    @StateObject private var color: DisplayProfileController
    @StateObject private var rotation: RotationController
    @State private var profiles: [ICCProfile] = []
    @State private var profilePath: URL?
    @State private var errorText: String?
    @State private var busy = false

    init(display: DisplayInfo, displayManager: DisplayManager) {
        self.display = display
        _modes = StateObject(wrappedValue: DisplayModeController(display: display, displayManager: displayManager))
        _color = StateObject(wrappedValue: DisplayProfileController(display: display))
        _rotation = StateObject(wrappedValue: RotationController(display: display, displayManager: displayManager))
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
                if rotation.isAvailable {
                    Picker("Rotation", selection: Binding(get: { rotation.current }, set: { rotation.select($0) })) {
                        ForEach(DisplayRotation.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    .disabled(rotation.pending != nil)
                }
                NotchView(display: display, inForm: true)
                if let message = modes.errorMessage ?? rotation.errorMessage ?? errorText {
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
            // No header: the slider row says Brightness, as in System Settings.
            Section {
                // The panel's slider (DDC, gamma or the system's own).
                LabeledContent("Brightness") {
                    BrightnessSliderView(display: display, compact: true, inForm: true)
                        .padding(.horizontal, -12)  // the panel's row inset
                        .frame(maxWidth: 300)
                }
                ExtraBrightnessView(display: display, inForm: true)
                SystemAutoBrightnessView(display: display)
            }
            Section("Connection") {
                AdvancedInputPicker(display: display)
                // A display stops being main only when another one becomes main.
                Toggle("Main Display", isOn: Binding(get: { display.isMain }, set: { if $0 { makeMain() } }))
                    .disabled(display.isMain)
                if !display.isBuiltin {
                    // On for a monitor that never answers the 0x62 probe read forces write-only
                    // volume (#57); off stops volume commands to a monitor whose DDC stops after
                    // repeated volume writes (#245). Shown whatever Show Volume Sliders says:
                    // the volume keys use DDC volume also with the sliders hidden.
                    CenteredToggle(title: "Volume Control", detail: Text(
                        "Speaker volume over DDC. Turn it off if the monitor stops answering, or on if it doesn't report volume."),
                                   isOn: Binding(
                        get: { display.volumeSupported },
                        set: { VolumeService.shared.setEnabled($0, for: display) }
                    ))
                }
                // Last, as on the card: it removes the display from this tab.
                if PhysicalDisplayToggleService.shared.isSupported,
                   !PhysicalDisplayToggleService.shared.wouldLeaveNoActiveDisplay(display.displayID) {
                    CenteredRow(title: "Disconnect Display",
                                detail: Text("Stays disconnected until you reconnect it from the menu bar.")) {
                        Button("Disconnect") { disconnect() }.disabled(busy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)  // the window's scroll view scrolls; this one took the wheel
        .onAppear {
            color.reload()
            rotation.reload()
        }
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

    private func disconnect() {
        busy = true
        Task { @MainActor in
            let result = await PhysicalDisplayToggleService.shared.disconnect(display)
            displayManager.refreshDisplays()
            if case .failure(let err) = result { showError(err.description) }
            busy = false
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

/// The card's Input row as a menu (#196). Choosing another input switches the monitor
/// and disconnects it, so the display leaves this tab; the way back is the Reconnect
/// row in the panel. Until Crisp knows this Mac's input, a choice only marks it.
private struct AdvancedInputPicker: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var service = InputSwitchService.shared
    @State private var pending = false
    @State private var message: String?

    private var uuid: String { display.displayUUID }

    var body: some View {
        if service.isAvailable(for: display) {
            CenteredRow(title: "Input", detail: detail) {
                Picker("Input", selection: Binding(get: { service.macInput[uuid] }, set: { if let value = $0 { choose(value) } })) {
                    if service.macInput[uuid] == nil { Text("").tag(UInt16?.none) }
                    ForEach(service.options(for: display), id: \.self) { Text(verbatim: inputLabel($0)).tag(Optional($0)) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(pending || service.reading.contains(uuid))
            }
            .task {
                await service.refreshInput(display)
                await service.readListIfNeeded(display)
            }
            if service.markedByUser.contains(uuid) {
                LabeledContent("") {
                    Button("Choose Again") { service.forgetMark(for: display) }.buttonStyle(.link)
                }
            }
        }
    }

    private var detail: Text {
        if let message { return Text(message).foregroundColor(.red) }
        if service.macInput[uuid] == nil { return Text("Crisp could not read which input this Mac is on. Choose it once.") }
        if PhysicalDisplayToggleService.shared.wouldLeaveNoActiveDisplay(display.displayID) {
            return Text("This is the only display, so it stays connected while it shows the other input.")
        }
        return Text("Another input disconnects this display. Reconnect it from the menu bar to switch back.")
    }

    private func choose(_ value: UInt16) {
        guard !pending, value != service.macInput[uuid] else { return }
        guard service.macInput[uuid] != nil else {
            service.mark(value, for: display)
            return
        }
        pending = true
        Task { @MainActor in
            let result = await service.switchInput(display, to: value)
            pending = false
            displayManager.refreshDisplays()
            if case .failure(let error) = result {
                message = error.description
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                message = nil
            }
        }
    }
}

/// A form row with its control centred on the title and the description, used for every
/// row with a description in this window (Didrik, 2026-11-19; a stock form row puts the
/// control level with the title). The fonts are the stock row's, compared in an
/// off-screen render.
private struct CenteredRow<Control: View>: View {
    let title: LocalizedStringKey
    let detail: Text
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                detail.font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            control
        }
    }
}

private struct CenteredToggle: View {
    let title: LocalizedStringKey
    let detail: Text
    @Binding var isOn: Bool

    var body: some View {
        CenteredRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).labelsHidden()
        }
    }
}
