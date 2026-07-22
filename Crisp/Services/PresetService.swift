import Foundation
import CoreGraphics

/// Manages display configuration presets: save, load, and one-click apply.
@MainActor
final class PresetService: ObservableObject, @unchecked Sendable {
    static let shared = PresetService()

    @Published var presets: [DisplayPreset] = []
    @Published var isApplying: Bool = false
    @Published var applyingPresetID: UUID? = nil

    /// Preset the user last applied. Shown as checked in the UI until any manual
    /// brightness/resolution/arrangement change invalidates it. Session-only.
    @Published var activePresetID: UUID? = nil

    /// Called by services when the user manually changes something a preset controls.
    func noteManualChange() {
        guard !isApplying else { return }
        if activePresetID != nil { activePresetID = nil }
    }

    private let filename = "presets.json"

    private init() {
        loadPresets()
    }

    // MARK: - Persistence

    func loadPresets() {
        let saved = SettingsService.shared.load([DisplayPreset].self, filename: filename) ?? []
        // Merge saved (non-builtin) with freshly generated built-ins
        let builtins = makeBuiltinPresets()
        let userPresets = saved.filter { !$0.isBuiltin }
        presets = builtins + userPresets
    }

    func savePresets() {
        // Only persist user-created presets; built-ins are always regenerated
        let toSave = presets.filter { !$0.isBuiltin }
        SettingsService.shared.save(toSave, filename: filename)
    }

    // MARK: - CRUD

    func addPreset(_ preset: DisplayPreset) {
        presets.append(preset)
        savePresets()
    }

    func deletePreset(id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              !presets[index].isBuiltin else { return }
        presets.remove(at: index)
        if activePresetID == id { activePresetID = nil }
        savePresets()
    }

    /// Overwrites a user preset with the current display state (name and icon kept).
    func updatePreset(id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              !presets[index].isBuiltin else { return }
        let captured = captureCurrentState(name: presets[index].name, icon: presets[index].icon)
        presets[index].displays = captured.displays
        savePresets()
        // The preset now matches the current state by definition.
        activePresetID = id
    }

    // MARK: - Apply

    /// Applies a preset: for each entry, finds the matching display and applies settings.
    func applyPreset(_ preset: DisplayPreset) async {
        guard !isApplying else {
            print("[PresetService] applyPreset: already applying, skipped")
            return
        }
        isApplying = true
        applyingPresetID = preset.id
        defer {
            isApplying = false
            applyingPresetID = nil
        }

        let displays = DisplayManagerAccessor.shared.displays
        print("[PresetService] applyPreset '\(preset.name)': \(displays.count) display(s) online, preset has \(preset.displays.count) entr(ies)")

        if displays.isEmpty {
            print("[PresetService] WARNING: displays list is empty – DisplayManagerAccessor may not be set up")
        }

        for (i, display) in displays.enumerated() {
            print("[PresetService]   display[\(i)] uuid=\(display.displayUUID) id=\(display.displayID) online=\(display.isOnline) modes=\(display.availableModes.count)")
        }

        var anyActionTaken = false

        for entry in preset.displays {
            print("[PresetService] entry uuid=\(entry.displayUUID) target=\(entry.width)×\(entry.height) hiDPI=\(entry.isHiDPI)")

            guard let display = displays.first(where: { $0.displayUUID == entry.displayUUID }) else {
                print("[PresetService]   -> no display matched UUID '\(entry.displayUUID)' – skipping")
                continue
            }
            guard display.isOnline else {
                print("[PresetService]   -> display '\(display.name)' is offline – skipping")
                continue
            }
            let displayID = display.displayID
            print("[PresetService]   -> matched display '\(display.name)' (id=\(displayID)), \(display.availableModes.count) available modes")

            // Set resolution — never change built-in display resolution via presets,
            // but built-in brightness and arrangement below still apply.
            if display.isBuiltin {
                print("[PresetService]   -> built-in display, skipping resolution")
            } else {
                let targetMode = display.availableModes.first(where: {
                    $0.width == entry.width &&
                    $0.height == entry.height &&
                    $0.isHiDPI == entry.isHiDPI
                }) ?? display.availableModes.first(where: {
                    $0.width == entry.width && $0.height == entry.height
                })

                if let mode = targetMode {
                    let currentMode = display.currentDisplayMode
                    let alreadyActive = currentMode?.width == mode.width
                        && currentMode?.height == mode.height
                        && currentMode?.isHiDPI == mode.isHiDPI
                    if alreadyActive {
                        print("[PresetService]   -> resolution \(mode.width)×\(mode.height) hiDPI=\(mode.isHiDPI) already active, skipping mode switch")
                    } else {
                        print("[PresetService]   -> setting mode \(mode.width)×\(mode.height) hiDPI=\(mode.isHiDPI)")
                        let ok = await ResolutionService.shared.setDisplayMode(mode, for: displayID)
                        print("[PresetService]   -> setDisplayMode result: \(ok)")
                        anyActionTaken = true
                    }
                } else {
                    print("[PresetService]   -> WARNING: no matching mode found for \(entry.width)×\(entry.height) hiDPI=\(entry.isHiDPI)")
                    print("[PresetService]      available: \(display.availableModes.map { "\($0.width)×\($0.height)/\($0.isHiDPI)" }.joined(separator: ", "))")
                }
            }

            // Set brightness if specified (convert 0.0-1.0 to 0-100 range used by BrightnessService).
            // Smooth variant fades over ~200ms instead of snapping.
            if let brightness = entry.brightness {
                print("[PresetService]   -> setting brightness \(brightness)")
                BrightnessService.shared.setBrightnessSmooth(
                    brightness * 100.0,
                    for: display,
                    isAutoAdjust: false,
                    duration: 0.5
                )
                anyActionTaken = true
            }

            // Set arrangement position if specified
            if let x = entry.arrangementX, let y = entry.arrangementY {
                print("[PresetService]   -> setting arrangement x=\(x) y=\(y)")
                let ok = await ArrangementService.shared.setPosition(
                    x: Int(x), y: Int(y), for: displayID
                )
                print("[PresetService]   -> setPosition result: \(ok)")
                anyActionTaken = true
            }
        }

        print("[PresetService] applyPreset '\(preset.name)' complete. anyActionTaken=\(anyActionTaken)")
        activePresetID = preset.id
        // DisplayManager is not a singleton; callers with a DisplayManager ref can call refreshDisplays().
    }

    // MARK: - Capture

    /// Snapshots all current online displays into a new preset.
    func captureCurrentState(name: String, icon: String) -> DisplayPreset {
        let displays = DisplayManagerAccessor.shared.displays
        let entries: [DisplayPresetEntry] = displays.compactMap { display in
            guard display.isOnline else { return nil }
            let mode = display.currentDisplayMode
            return DisplayPresetEntry(
                displayUUID: display.displayUUID,
                width: mode?.width ?? display.pixelWidth,
                height: mode?.height ?? display.pixelHeight,
                isHiDPI: mode?.isHiDPI ?? false,
                brightness: display.brightness / 100.0,
                arrangementX: display.bounds.origin.x,
                arrangementY: display.bounds.origin.y
            )
        }
        return DisplayPreset(name: name, icon: icon, displays: entries)
    }

    /// Returns the preset ID that matches the current display state, if any.
    func currentPresetMatch() -> UUID? {
        let displays = DisplayManagerAccessor.shared.displays
        for preset in presets {
            let matches = preset.displays.allSatisfy { entry in
                guard let display = displays.first(where: { $0.displayUUID == entry.displayUUID }),
                      display.isOnline else { return false }
                // Built-in entries never drive resolution, so they don't gate matching
                if display.isBuiltin { return true }
                let mode = display.currentDisplayMode
                let modeMatch = mode?.width == entry.width && mode?.height == entry.height
                return modeMatch
            }
            if matches && !preset.displays.isEmpty { return preset.id }
        }
        return nil
    }

    // MARK: - Built-in Presets

    /// Regenerates built-in presets from the current display list and merges with user presets.
    /// Call this whenever the display list changes (e.g., after DisplayManager.refreshDisplays).
    func refreshBuiltins() {
        let userPresets = presets.filter { !$0.isBuiltin }
        presets = makeBuiltinPresets() + userPresets
    }

    private func makeBuiltinPresets() -> [DisplayPreset] {
        // Presets only manage external displays — never touch the built-in screen
        let externals = DisplayManagerAccessor.shared.displays.filter { $0.isOnline && !$0.isBuiltin }
        guard !externals.isEmpty else { return [] }

        // --- Native mode ---
        let nativeEntries: [DisplayPresetEntry] = externals.map { display in
            let nativeMode: DisplayMode? = display.availableModes
                .filter { !$0.isHiDPI }
                .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
                ?? display.availableModes.max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
                ?? display.currentDisplayMode
            return DisplayPresetEntry(
                displayUUID: display.displayUUID,
                width: nativeMode?.width ?? display.pixelWidth,
                height: nativeMode?.height ?? display.pixelHeight,
                isHiDPI: nativeMode?.isHiDPI ?? false,
                brightness: nil,
                arrangementX: nil,
                arrangementY: nil
            )
        }

        var nativePreset = DisplayPreset(
            name: "Native Mode",
            icon: "rectangle.on.rectangle",
            displays: nativeEntries
        )
        nativePreset.isBuiltin = true

        var result: [DisplayPreset] = [nativePreset]

        // --- HiDPI mode ---
        // Find the best HiDPI mode for each external display (highest logical resolution)
        let hasExternalWithHiDPI = externals.contains { display in
            display.availableModes.contains { $0.isHiDPI }
        }

        if hasExternalWithHiDPI {
            let hidpiEntries: [DisplayPresetEntry] = externals.map { display in
                // Pick the highest-resolution HiDPI mode available
                if let bestHiDPI = display.availableModes
                    .filter({ $0.isHiDPI })
                    .max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) {
                    return DisplayPresetEntry(
                        displayUUID: display.displayUUID,
                        width: bestHiDPI.width,
                        height: bestHiDPI.height,
                        isHiDPI: true,
                        brightness: nil,
                        arrangementX: nil,
                        arrangementY: nil
                    )
                } else {
                    let nativeMode = display.availableModes
                        .filter { !$0.isHiDPI }
                        .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
                    return DisplayPresetEntry(
                        displayUUID: display.displayUUID,
                        width: nativeMode?.width ?? display.pixelWidth,
                        height: nativeMode?.height ?? display.pixelHeight,
                        isHiDPI: nativeMode?.isHiDPI ?? false,
                        brightness: nil,
                        arrangementX: nil,
                        arrangementY: nil
                    )
                }
            }
            var hidpiPreset = DisplayPreset(
                name: "HiDPI Mode",
                icon: "sparkles",
                displays: hidpiEntries
            )
            hidpiPreset.isBuiltin = true
            result.append(hidpiPreset)
        }

        return result
    }
}
