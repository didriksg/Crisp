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
        presets = SettingsService.shared.load([DisplayPreset].self, filename: filename) ?? []
    }

    func savePresets() {
        SettingsService.shared.save(presets, filename: filename)
        // Shortcuts live on presets, so any preset change may add/remove/steal one.
        HotkeyService.shared.syncRegistrations()
    }

    // MARK: - CRUD

    func addPreset(_ preset: DisplayPreset) {
        presets.append(preset)
        savePresets()
    }

    func deletePreset(id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets.remove(at: index)
        if activePresetID == id { activePresetID = nil }
        savePresets()
    }

    // MARK: - Shortcuts (issue #61)

    /// Sets a preset's shortcut, stealing the combo from every other holder
    /// (other presets and the static Toggle HiDPI action): last save wins.
    func commitShortcut(_ shortcut: KeyboardShortcut?, forPresetID id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        if let shortcut {
            for i in presets.indices where presets[i].id != id
                && presets[i].shortcut?.sameKeys(as: shortcut) == true {
                presets[i].shortcut = nil
            }
            if SettingsService.shared.hidpiShortcut?.sameKeys(as: shortcut) == true {
                SettingsService.shared.hidpiShortcut = nil
            }
        }
        presets[index].shortcut = shortcut
        savePresets()
    }

    /// The static Toggle HiDPI action recorded a combo: steal it from any preset
    /// holding it, then re-register. Call after storing the new static combo.
    func stealShortcutFromPresets(_ shortcut: KeyboardShortcut) {
        var changed = false
        for i in presets.indices where presets[i].shortcut?.sameKeys(as: shortcut) == true {
            presets[i].shortcut = nil
            changed = true
        }
        if changed {
            savePresets()  // persists and syncs
        } else {
            HotkeyService.shared.syncRegistrations()  // still need the new static hotkey
        }
    }

    /// Overwrites a user preset with the current display state (name, icon, and
    /// which attributes it controls are kept).
    func updatePreset(id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let existing = presets[index]
        let captured = captureCurrentState(
            name: existing.name, icon: existing.icon,
            includeResolution: existing.includesResolution,
            includeBrightness: existing.includesBrightness,
            includeArrangement: existing.includesArrangement
        )
        presets[index].displays = captured.displays
        savePresets()
        // The preset now matches the current state by definition.
        activePresetID = id
    }

    /// Edits an existing user preset's identity and capture inclusions. Identity
    /// (name/icon/color) updates directly; a capture is only dropped or
    /// re-captured when its inclusion actually changed, so captures left alone
    /// keep their stored values across a rename.
    func editPreset(id: UUID, name: String, icon: String, colorName: String?,
                    includeResolution: Bool, includeBrightness: Bool, includeArrangement: Bool) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = name
        presets[index].icon = icon
        presets[index].colorName = colorName
        savePresets()
        for (capture, want) in [(PresetCapture.resolution, includeResolution),
                                (.brightness, includeBrightness),
                                (.arrangement, includeArrangement)]
        where presets[index].includes(capture) != want {
            setCapture(id: id, capture, included: want)
        }
    }

    /// Flips whether a preset controls one attribute. Turning it off drops the
    /// stored value (nil, so apply skips it); turning it back on re-captures the
    /// current live value for each of the preset's displays. A display that's
    /// offline can't be re-captured, so its entry stays excluded.
    func setCapture(id: UUID, _ capture: PresetCapture, included: Bool) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let displays = DisplayManagerAccessor.shared.displays
        presets[index].displays = presets[index].displays.map { entry in
            var e = entry
            let live = displays.first(where: { $0.displayUUID == entry.displayUUID && $0.isOnline })
            switch capture {
            case .resolution:
                if included, let live {
                    let mode = live.currentDisplayMode
                    e.width = mode?.width ?? live.pixelWidth
                    e.height = mode?.height ?? live.pixelHeight
                    e.isHiDPI = mode?.isHiDPI ?? false
                    e.refreshRate = mode?.refreshRate
                } else if !included {
                    e.width = nil; e.height = nil; e.isHiDPI = nil; e.refreshRate = nil
                }
            case .brightness:
                if included, let live {
                    e.brightness = live.brightness / 100.0
                } else if !included {
                    e.brightness = nil
                }
            case .arrangement:
                if included, let live {
                    e.arrangementX = live.bounds.origin.x
                    e.arrangementY = live.bounds.origin.y
                } else if !included {
                    e.arrangementX = nil; e.arrangementY = nil
                }
            }
            return e
        }
        savePresets()
        // What the preset controls changed; it no longer cleanly represents the
        // last-applied state.
        if activePresetID == id { activePresetID = nil }
    }

    // MARK: - Apply

    /// Applies a preset: for each entry, finds the matching display and applies settings.
    func applyPreset(_ preset: DisplayPreset) async {
        guard !isApplying else { return }
        isApplying = true
        applyingPresetID = preset.id
        defer {
            isApplying = false
            applyingPresetID = nil
        }

        let displays = DisplayManagerAccessor.shared.displays
        var resolutionsApplied = true

        for entry in preset.displays {
            guard let display = displays.first(where: { $0.displayUUID == entry.displayUUID }) else { continue }
            guard display.isOnline else { continue }
            let displayID = display.displayID

            // Set resolution, only when the preset includes it (width present).
            // The built-in panel is driven too: a preset restores whatever mode was
            // live when it was captured, so an unchanged built-in resolves to the
            // alreadyActive no-op below. Brightness and arrangement apply regardless.
            if let w = entry.width, let h = entry.height {
                let hiDPI = entry.isHiDPI ?? false
                let beyondCapStops = MirroredModeService.beyondCapStops(for: display).map {
                    PanelResolution(width: $0.width, height: $0.height)
                }
                let route = PresetResolutionRouter.route(
                    width: w, height: h, isHiDPI: hiDPI,
                    candidates: display.availableModes.map {
                        PresetModeCandidate(width: $0.width, height: $0.height,
                                            isHiDPI: $0.isHiDPI)
                    },
                    beyondCapStops: beyondCapStops)

                switch route {
                case .mirror:
                    // Route before the physical fallback: beyond-cap sizes often
                    // have a same-size 1× mode, but restoring that would be blurry.
                    let applied = await MirroredModeService.shared.apply(
                        display: display, width: w, height: h)
                    resolutionsApplied = resolutionsApplied && applied
                case let .physical(index):
                    let mode = display.availableModes[index]
                    // Keep teardown and the physical mode transaction atomic
                    // against a concurrent mirror request. Even an apparently
                    // already-active physical mode must first leave mirror mode.
                    let applied = await MirroredModeService.shared.withMirrorRestored(for: display) {
                        let changed = await ResolutionService.shared.setDisplayMode(
                            mode, for: displayID,
                            expectedDisplayUUID: display.displayUUID)
                        if changed {
                            // refreshDisplays() doesn't re-read the current mode for
                            // already-present displays, so write it back here (as the manual
                            // switch does) or the panel keeps showing the old resolution.
                            display.currentDisplayMode = mode
                        }
                        return changed
                    }
                    resolutionsApplied = resolutionsApplied && applied
                case .unavailable:
                    resolutionsApplied = false
                }
            }

            // Set brightness if specified (convert 0.0-1.0 to 0-100 range used by BrightnessService).
            // Smooth variant fades over ~200ms instead of snapping.
            if let brightness = entry.brightness {
                BrightnessService.shared.setBrightnessSmooth(
                    brightness * 100.0,
                    for: display,
                    isAutoAdjust: false,
                    duration: 0.5
                )
            }

            // Set arrangement position if specified
            if let x = entry.arrangementX, let y = entry.arrangementY {
                _ = await ArrangementService.shared.setPosition(
                    x: Int(x), y: Int(y), for: displayID
                )
            }
        }

        activePresetID = resolutionsApplied ? preset.id : nil
        // DisplayManager is not a singleton; callers with a DisplayManager ref can call refreshDisplays().
    }

    // MARK: - Capture

    /// Snapshots all current online displays into a new preset. The include
    /// flags decide which attributes the preset controls; an excluded attribute
    /// is stored as nil and won't be touched on apply.
    func captureCurrentState(name: String, icon: String,
                             includeResolution: Bool = true,
                             includeBrightness: Bool = true,
                             includeArrangement: Bool = true) -> DisplayPreset {
        let displays = DisplayManagerAccessor.shared.displays
        let entries: [DisplayPresetEntry] = displays.compactMap { display in
            guard display.isOnline else { return nil }
            let mode = display.currentDisplayMode
            return DisplayPresetEntry(
                displayUUID: display.displayUUID,
                width: includeResolution ? (mode?.width ?? display.pixelWidth) : nil,
                height: includeResolution ? (mode?.height ?? display.pixelHeight) : nil,
                isHiDPI: includeResolution ? (mode?.isHiDPI ?? false) : nil,
                refreshRate: includeResolution ? mode?.refreshRate : nil,
                brightness: includeBrightness ? display.brightness / 100.0 : nil,
                arrangementX: includeArrangement ? display.bounds.origin.x : nil,
                arrangementY: includeArrangement ? display.bounds.origin.y : nil
            )
        }
        return DisplayPreset(name: name, icon: icon, displays: entries)
    }

    /// Returns the preset ID that matches the current display state, if any.
    func currentPresetMatch() -> UUID? {
        let displays = DisplayManagerAccessor.shared.displays
        for preset in presets {
            // Match is resolution-defined; brightness/arrangement-only presets don't participate.
            guard preset.includesResolution else { continue }
            let matches = preset.displays.allSatisfy { entry in
                guard let display = displays.first(where: { $0.displayUUID == entry.displayUUID }),
                      display.isOnline else { return false }
                // Entry without a resolution doesn't gate on it
                guard let w = entry.width, let h = entry.height else { return true }
                let mode = display.currentDisplayMode
                return mode?.width == w && mode?.height == h
            }
            if matches && !preset.displays.isEmpty { return preset.id }
        }
        return nil
    }

}
