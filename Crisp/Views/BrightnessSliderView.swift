import SwiftUI

/// Sun step icon flanking a brightness slider: brightens while pressed, steps
/// once on click, and keeps stepping while held (initial delay, then repeat),
/// like holding a hardware brightness key.
struct BrightnessStepButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        // A Button, not a raw DragGesture: the panel's ScrollView steals a
        // DragGesture, so onEnded never fires and "pressed" sticks on.
        // ButtonStyle.isPressed always resets on release instead.
        Button(action: {}) {
            Image(systemName: systemName)
                .font(.system(size: 15))
        }
        .buttonStyle(HoldRepeatButtonStyle(action: action))
        .accessibilityHidden(true)
    }
}

/// Lights the glyph only while physically held, and repeats the step action
/// (initial delay, then steady repeat) for as long as it stays held.
private struct HoldRepeatButtonStyle: ButtonStyle {
    let action: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        HoldRepeatLabel(configuration: configuration, action: action)
    }

    private struct HoldRepeatLabel: View {
        let configuration: ButtonStyleConfiguration
        let action: () -> Void
        @State private var repeatTask: Task<Void, Never>? = nil

        var body: some View {
            configuration.label
                .foregroundColor(configuration.isPressed ? .primary : .secondary)
                .contentShape(Rectangle())
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed {
                        action()
                        repeatTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(nanoseconds: 150_000_000)
                            }
                        }
                    } else {
                        repeatTask?.cancel()
                        repeatTask = nil
                    }
                }
        }
    }
}

struct BrightnessSliderView: View {
    @ObservedObject var display: DisplayInfo
    var compact: Bool = false  // Compact mode: hides the mode label row (used for top-level inline sliders)
    @State private var localBrightness: Double = 50
    @State private var isDragging: Bool = false
    @State private var ddcStatus: Bool? = nil  // nil=unknown, true=DDC, false=Software
    // Track-click vs drag: defer the first value change of an editing session. A click
    // produces a single change (glide it on release); a drag produces a stream (write live).
    @State private var dragConfirmed: Bool = false
    @State private var deferredFirstChange: Bool = false
    // While a click's fade runs, hold the thumb at the target (see the
    // display.brightness onChange below) instead of snapping back through the fade.
    @State private var clickGliding: Bool = false

    /// Debug switch: `defaults write com.crisp.app crisp.showBrightnessControlMode -bool true`
    /// (relaunch) shows the DDC/software mode row on every slider, for support threads.
    /// Read once at launch; no Settings row on purpose.
    /// ponytail: reads the DDC latch only; an HDR-dimmed external shows "DDC" while
    /// writing gamma. Fold in BrightnessService.hdrDimmedDisplays if that misleads.
    static let showControlMode = UserDefaults.standard.bool(forKey: "crisp.showBrightnessControlMode")

    var body: some View {
        VStack(spacing: 2) {
            // Shown outside compact mode, or always when the debug switch is set.
            if !compact || Self.showControlMode {
            HStack(spacing: 4) {
                Spacer()
                if display.hasNativeBrightness {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text("System")
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else if let status = ddcStatus {
                    Circle()
                        .fill(status ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(status ? "DDC" : "Software")
                        .font(.caption2)
                        .foregroundColor(status ? .green : .orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .accessibilityLabel(
                display.hasNativeBrightness
                    ? "Brightness control mode: System"
                    : (ddcStatus == true
                        ? "Brightness control mode: DDC hardware"
                        : "Brightness control mode: Software emulation")
            )
            }

            HStack(spacing: 8) {
                BrightnessStepButton(systemName: "sun.min.fill") { step(-brightnessStep) }

                // Native macOS slider, exactly as in the system Display panel.
                Slider(value: $localBrightness, in: 0...max(100.0, display.maxBrightness)) { editing in
                    if editing {
                        isDragging = true
                        dragConfirmed = false
                        deferredFirstChange = false
                    } else {
                        isDragging = false
                        if !dragConfirmed {
                            // A click glides to the target instead of jumping, like
                            // brightness keys and presets. Hold the thumb until it lands.
                            // Measured: see docs/ui-notes.md (BrightnessSliderView: click-glide fade)
                            clickGliding = true
                            BrightnessService.shared.setBrightnessSmooth(localBrightness, for: display, duration: 0.2)
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 600_000_000)  // fallback release
                                clickGliding = false
                                updateDDCStatus()
                            }
                        } else {
                            Task { @MainActor in
                                // Flush the final value; the coalescing writer already tracked the drag.
                                await BrightnessService.shared.setBrightness(localBrightness, for: display)
                                updateDDCStatus()
                            }
                        }
                    }
                }
                .modifier(BoostTintModifier(progress: localBrightness > 100.5 ? 1 : 0))
                .animation(.easeInOut(duration: 0.3), value: localBrightness > 100.5)
                .overlay {
                    if display.maxBrightness > 100 {
                        GeometryReader { geo in
                            // Notch at 100%: track to its right is Extra Brightness.
                            // ponytail: inset is eyeballed for .small; retune if it
                            // drifts off the thumb center at 100.
                            let inset: CGFloat = 10
                            let usable = geo.size.width - inset * 2
                            let x = inset + usable * 100.0 / display.maxBrightness
                            RoundedRectangle(cornerRadius: 0.75)
                                .fill(Color.secondary.opacity(0.55))
                                .frame(width: 1.5, height: 8)
                                .position(x: x, y: geo.size.height / 2)
                        }
                        .allowsHitTesting(false)
                    }
                }
                // Matches Control Center's own slider size per OS version.
                // Measured: see docs/ui-notes.md (BrightnessSliderView: control size by OS)
                .controlSize(SystemLook.isMacOS27OrLater ? .regular : .small)
                .accessibilityLabel("Display brightness")
                .accessibilityValue("\(Int(localBrightness))%")
                .onChange(of: localBrightness) { _, newValue in
                    guard isDragging else { return }
                    if dragConfirmed {
                        // Applies immediately; the service picks DDC or software and paces writes.
                        display.brightness = newValue
                        Task { @MainActor in
                            await BrightnessService.shared.setBrightness(newValue, for: display)
                        }
                    } else if !deferredFirstChange {
                        // Defer the first change so a click can glide instead of jumping.
                        deferredFirstChange = true
                    } else {
                        // Second change confirms a real drag: go live from here.
                        dragConfirmed = true
                        display.brightness = newValue
                        Task { @MainActor in
                            await BrightnessService.shared.setBrightness(newValue, for: display)
                        }
                    }
                }

                BrightnessStepButton(systemName: "sun.max.fill") { step(brightnessStep) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .task(id: display.displayID) {
            localBrightness = display.brightness
            updateDDCStatus()
        }
        .onChange(of: display.brightness) { _, newValue in
            // Holds at the click target until the fade catches up (see click-glide above).
            if clickGliding {
                if abs(newValue - localBrightness) < 0.75 { clickGliding = false }
                return
            }
            // External change (preset fade, keys, another app): NSSlider doesn't
            // interpolate, so track every fade step with a low threshold.
            if !isDragging && abs(newValue - localBrightness) >= 0.1 {
                localBrightness = newValue
            }
        }
    }

    /// Animates the slider tint accent -> boost yellow past 100: .tint doesn't
    /// interpolate on its own, so progress is the animatable data.
    private struct BoostTintModifier: ViewModifier, Animatable {
        var progress: Double
        // ViewModifier's body puts the modifier on the main actor, while
        // Animatable's data is read off it, so this accessor says so itself.
        nonisolated var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }
        func body(content: Content) -> some View {
            content.tint(boostTint)
        }

        private var boostTint: Color {
            guard progress > 0 else { return .accentColor }
            let fraction = min(1.0, progress)
            if #available(macOS 15.0, *) {
                return Color.accentColor.mix(with: .yellow, by: fraction)
            }
            // macOS 14: Color.mix is 15+; AppKit's blend interpolates in a
            // slightly different space, indistinguishable across a tint ramp.
            return Color(nsColor: NSColor.controlAccentColor
                .blended(withFraction: fraction, of: .systemYellow) ?? .controlAccentColor)
        }
    }

    private func updateDDCStatus() {
        ddcStatus = BrightnessService.shared.isDDCAvailable(for: display.displayID)
    }

    /// Brightness change per tap (and per hold-repeat) of the sun buttons.
    private var brightnessStep: Double { 10.0 }

    private func step(_ delta: Double) {
        let target = max(0, min(display.maxBrightness, display.brightness + delta))
        // The smooth fade updates display.brightness per frame; localBrightness
        // follows through the existing onChange sync.
        BrightnessService.shared.setBrightnessSmooth(target, for: display)
    }
}

struct CombinedBrightnessView: View {
    let displays: [DisplayInfo]
    @ObservedObject private var settings = SettingsService.shared
    @State private var combinedBrightness: Double = 50
    @State private var isDragging: Bool = false
    @State private var dragConfirmed: Bool = false
    @State private var deferredFirstChange: Bool = false
    @State private var clickGliding: Bool = false

    /// Externals define the shared scale; unlike the built-in panel, their
    /// current DDC percentage is already the combined control's reference.
    private var referenceDisplays: [DisplayInfo] {
        let externals = displays.filter { !$0.isBuiltin }
        return externals.isEmpty ? displays : externals
    }

    private var referenceMaxNits: Double? {
        let values = referenceDisplays.compactMap(\.nominalMaxNits)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var averageBrightness: Double {
        guard !referenceDisplays.isEmpty else { return 50 }
        return referenceDisplays.map {
            CombinedBrightnessMath.controlValue(
                brightness: $0.brightness,
                maxBrightness: $0.maxBrightness,
                displayMaxNits: $0.nominalMaxNits,
                referenceMaxNits: referenceMaxNits)
        }.reduce(0, +) / Double(referenceDisplays.count)
    }

    private func targetBrightness(_ combined: Double, for display: DisplayInfo) -> Double {
        guard !display.isBuiltin else {
            return combined / 100.0 * display.maxBrightness
        }
        return CombinedBrightnessMath.targetBrightness(
            combined: combined,
            maxBrightness: display.maxBrightness,
            displayMaxNits: display.nominalMaxNits,
            referenceMaxNits: referenceMaxNits)
    }

    private func builtinLinearTarget(_ combined: Double, for display: DisplayInfo) -> Double? {
        guard display.isBuiltin, display.maxBrightness <= 100.5,
              BrightnessService.supportsLinearBrightness,
              let referenceMaxNits,
              let builtinMaxNits = display.nominalMaxNits else { return nil }
        return CombinedBrightnessMath.builtinLinearTarget(
            combined: combined,
            referenceMaxNits: referenceMaxNits,
            builtinMaxNits: builtinMaxNits,
            adjustment: settings.combinedBuiltinBrightnessFactor)
    }

    private func setSmooth(_ combined: Double, for display: DisplayInfo) {
        if let linear = builtinLinearTarget(combined, for: display) {
            BrightnessService.shared.setBuiltinLinearBrightnessSmooth(linear, for: display)
        } else {
            BrightnessService.shared.setBrightnessSmooth(
                targetBrightness(combined, for: display), for: display)
        }
    }

    private func setImmediate(_ combined: Double, for display: DisplayInfo) async {
        if let linear = builtinLinearTarget(combined, for: display) {
            await BrightnessService.shared.setBuiltinLinearBrightness(linear, for: display)
        } else {
            let target = targetBrightness(combined, for: display)
            display.brightness = target
            await BrightnessService.shared.setBrightness(target, for: display)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Matches DisplayRowView's bold title so this reads as another row.
            // 14pt inset matches the display titles; the slider below uses 12pt.
            Text("Combined")
                .fontWeight(.semibold)
                .lineLimit(1)
                .padding(.horizontal, 14)

            HStack(spacing: 8) {
                BrightnessStepButton(systemName: "sun.min.fill") { stepAll(-10.0) }

                Slider(value: $combinedBrightness, in: 0...100) { editing in
                    if editing {
                        isDragging = true
                        dragConfirmed = false
                        deferredFirstChange = false
                    } else {
                        isDragging = false
                        if !dragConfirmed {
                            // Same click-glide as the per-display slider (see above);
                            // hold the handle until the probe-driven fades land.
                            clickGliding = true
                            for display in displays {
                                setSmooth(combinedBrightness, for: display)
                            }
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 600_000_000)  // fallback release
                                clickGliding = false
                            }
                        } else {
                            // Drag ended, flush final value to all displays.
                            Task { @MainActor in
                                for display in displays {
                                    await setImmediate(combinedBrightness, for: display)
                                }
                            }
                        }
                    }
                }
                .tint(Color.accentColor)
                .controlSize(SystemLook.isMacOS27OrLater ? .regular : .small)
                .accessibilityLabel("Combined brightness")
                .accessibilityValue("\(Int(combinedBrightness))%")
                .onChange(of: combinedBrightness) { _, newValue in
                    guard isDragging else { return }
                    if !dragConfirmed {
                        // Defer the first change, as in BrightnessSliderView.
                        if !deferredFirstChange { deferredFirstChange = true; return }
                        dragConfirmed = true
                    }
                    Task { @MainActor in
                        for display in displays {
                            await setImmediate(newValue, for: display)
                        }
                    }
                }

                BrightnessStepButton(systemName: "sun.max.fill") { stepAll(10.0) }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
        .background {
            // Mirrors the displays' real brightness so the combined handle glides in
            // sync; skipped while dragging (the drag itself drives the displays).
            ForEach(displays) { display in
                BrightnessProbe(display: display) {
                    // Same click-glide hold as the per-display slider.
                    if clickGliding {
                        if abs(averageBrightness - combinedBrightness) < 0.75 { clickGliding = false }
                        return
                    }
                    if !isDragging { combinedBrightness = averageBrightness }
                }
            }
        }
        .onChange(of: settings.combinedBuiltinBrightnessFactor) { _, _ in
            // Visible immediately: keep the external reference fixed, re-aim the built-in.
            guard !isDragging else { return }
            combinedBrightness = averageBrightness
            for display in displays where display.isBuiltin {
                setSmooth(combinedBrightness, for: display)
            }
        }
        .onAppear {
            combinedBrightness = averageBrightness
        }
    }

    private func stepAll(_ delta: Double) {
        let target = max(0, min(100, combinedBrightness + delta))
        // Handle is not moved here; it follows the displays' real brightness via
        // BrightnessProbe, so it stays in sync instead of running its own ramp.
        for display in displays {
            setSmooth(target, for: display)
        }
    }
}

/// Invisible observer of one display's brightness. Lets an aggregate control (the
/// combined slider) react to the displays' real per-frame fade without owning a
/// separate animation. Zero-sized, so it adds nothing to layout.
private struct BrightnessProbe: View {
    @ObservedObject var display: DisplayInfo
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: display.brightness) { _, _ in onChange() }
    }
}
