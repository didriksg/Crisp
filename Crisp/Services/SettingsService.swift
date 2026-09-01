import Foundation
import CoreGraphics
import Combine

/// Which displays the hardware brightness keys act on.
/// Persisted (raw value) via `SettingsService.brightnessKeyTarget`.
enum BrightnessKeyTarget: String, CaseIterable, Codable {
    case underCursor   // only the display under the pointer (current behaviour)
    case allDisplays   // every connected display
    case selected      // only a user-chosen subset (see brightnessKeySelectedDisplays)
}

/// Centralized settings persistence service.
/// Simple settings use UserDefaults via @AppStorage-compatible keys.
/// Complex configurations are stored as JSON in ~/Library/Application Support/Crisp/.
@MainActor
final class SettingsService: ObservableObject, @unchecked Sendable {
    static let shared = SettingsService()

    private let defaults = UserDefaults.standard
    private let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Crisp", isDirectory: true)
        // One-time migration from the pre-rename storage folder.
        let legacy = base.appendingPathComponent("FreeDisplay", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        loadAll()
        // Re-sync launch-at-login from the authoritative SMAppService state on every panel
        // open, so toggling Crisp in System Settings > Login Items reflects without a
        // relaunch. No OS notification exists for login-item changes, so panel-open is the
        // cheapest reliable hook. Only the didSet (a UserDefaults write) runs on assignment,
        // never a re-register, so this can't fight the user's own toggle. Singleton -> no teardown.
        NotificationCenter.default.addObserver(
            forName: .crispPanelDidOpen, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let actual = LaunchService.shared.isEnabled
                if self.launchAtLogin != actual { self.launchAtLogin = actual }
            }
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let launchAtLogin          = "crisp.launchAtLogin"
        static let launchAtLoginPrompted  = "crisp.launchAtLogin.prompted"
        static let menuWidth              = "crisp.menuWidth"
        static let showCombinedBrightness = "crisp.showCombinedBrightness"
        static let showVolumeSliders      = "crisp.showVolumeSliders"
        static let ddcCacheTTL            = "crisp.ddcCacheTTL"
        static let colorPickerHistory     = "crisp.colorPickerHistory"
        static let brightnessKeyTarget    = "crisp.brightnessKeyTarget"
        static let brightnessKeySelected  = "crisp.brightnessKeySelectedDisplays"
        static let hidpiShortcut          = "crisp.hidpiShortcut"
        // Per-display keys use prefix + displayID
        static let brightnessPrefix       = "crisp.brightness_"
        static let contrastPrefix         = "crisp.contrast_"
        // Stable physical identity, not CGDirectDisplayID (which changes on reconnect).
        static let panelResolutionPrefix  = "crisp.panelResolution_"
    }

    // MARK: - Published Settings

    @Published var launchAtLogin: Bool = false {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// Whether the first-launch "enable Launch at Login?" prompt has been shown.
    @Published var launchAtLoginPrompted: Bool = false {
        didSet { defaults.set(launchAtLoginPrompted, forKey: Keys.launchAtLoginPrompted) }
    }

    @Published var menuWidth: Double = 320 {
        didSet { defaults.set(menuWidth, forKey: Keys.menuWidth) }
    }

    @Published var showCombinedBrightness: Bool = true {
        didSet { defaults.set(showCombinedBrightness, forKey: Keys.showCombinedBrightness) }
    }

    /// Volume sliders for DDC-volume monitors. Hiding them only affects the
    /// panel; the volume keys keep routing to the monitor.
    @Published var showVolumeSliders: Bool = true {
        didSet { defaults.set(showVolumeSliders, forKey: Keys.showVolumeSliders) }
    }

    @Published var ddcCacheTTL: Double = 5.0 {
        didSet { defaults.set(ddcCacheTTL, forKey: Keys.ddcCacheTTL) }
    }

    /// Recently sampled colors (hex strings, newest first, max 20).
    @Published var colorPickerHistory: [String] = [] {
        didSet {
            defaults.set(colorPickerHistory, forKey: Keys.colorPickerHistory)
        }
    }

    /// Which displays the brightness keys act on. Default: the display under the cursor.
    @Published var brightnessKeyTarget: BrightnessKeyTarget = .underCursor {
        didSet { defaults.set(brightnessKeyTarget.rawValue, forKey: Keys.brightnessKeyTarget) }
    }

    /// Displays chosen for the `.selected` brightness-key mode, stored by stable
    /// DisplayInfo.displayUUID (not the volatile CGDirectDisplayID, which macOS can
    /// reassign across reconnects). Ignored unless brightnessKeyTarget == .selected.
    @Published var brightnessKeySelectedDisplayUUIDs: Set<String> = [] {
        didSet {
            defaults.set(Array(brightnessKeySelectedDisplayUUIDs), forKey: Keys.brightnessKeySelected)
        }
    }

    /// Global shortcut that toggles the display under the pointer between HiDPI and
    /// low resolution; nil when not set. Registration is the caller's job
    /// (HotkeyService.syncRegistrations), matching how LaunchService is driven from the view.
    @Published var hidpiShortcut: KeyboardShortcut? = nil {
        didSet {
            if let hidpiShortcut, let data = try? JSONEncoder().encode(hidpiShortcut) {
                defaults.set(data, forKey: Keys.hidpiShortcut)
            } else {
                defaults.removeObject(forKey: Keys.hidpiShortcut)
            }
        }
    }

    // MARK: - Per-Display Settings

    func brightness(for displayID: CGDirectDisplayID) -> Double? {
        let key = Keys.brightnessPrefix + "\(displayID)"
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        defaults.set(value, forKey: Keys.brightnessPrefix + "\(displayID)")
    }

    func contrast(for displayID: CGDirectDisplayID) -> Double? {
        let key = Keys.contrastPrefix + "\(displayID)"
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    func setContrast(_ value: Double, for displayID: CGDirectDisplayID) {
        defaults.set(value, forKey: Keys.contrastPrefix + "\(displayID)")
    }

    func panelResolutionOverride(vendor: UInt32, product: UInt32,
                                 serial: UInt32) -> PanelResolution? {
        guard let values = defaults.array(forKey: panelResolutionKey(
            vendor: vendor, product: product, serial: serial
        )) as? [Int], values.count == 2 else { return nil }
        let resolution = PanelResolution(width: values[0], height: values[1])
        return resolution.isPlausible ? resolution : nil
    }

    func setPanelResolutionOverride(_ resolution: PanelResolution?, vendor: UInt32,
                                    product: UInt32, serial: UInt32) {
        let key = panelResolutionKey(vendor: vendor, product: product, serial: serial)
        if let resolution, resolution.isPlausible {
            defaults.set([resolution.width, resolution.height], forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func panelResolutionKey(vendor: UInt32, product: UInt32,
                                    serial: UInt32) -> String {
        Keys.panelResolutionPrefix + "\(vendor)-\(product)-\(serial)"
    }

    // MARK: - Color History

    func addColorToHistory(_ hex: String) {
        var history = colorPickerHistory.filter { $0 != hex }
        history.insert(hex, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        colorPickerHistory = history
    }

    // MARK: - JSON Persistence Helpers

    func save<T: Encodable>(_ value: T, filename: String) {
        let url = supportDir.appendingPathComponent(filename)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            // best-effort persistence; a failed write is non-fatal
        }
    }

    func load<T: Decodable>(_ type: T.Type, filename: String) -> T? {
        let url = supportDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Load All

    private func loadAll() {
        // Sync launch-at-login from the authoritative SMAppService state, not just UserDefaults.
        // This handles the case where the user toggled it externally or after a fresh install.
        launchAtLogin = LaunchService.shared.isEnabled
        launchAtLoginPrompted = defaults.bool(forKey: Keys.launchAtLoginPrompted)
        menuWidth = defaults.object(forKey: Keys.menuWidth) != nil
            ? defaults.double(forKey: Keys.menuWidth) : 320
        showCombinedBrightness = defaults.object(forKey: Keys.showCombinedBrightness) != nil
            ? defaults.bool(forKey: Keys.showCombinedBrightness) : true
        showVolumeSliders = defaults.object(forKey: Keys.showVolumeSliders) != nil
            ? defaults.bool(forKey: Keys.showVolumeSliders) : true
        ddcCacheTTL = defaults.object(forKey: Keys.ddcCacheTTL) != nil
            ? defaults.double(forKey: Keys.ddcCacheTTL) : 5.0
        colorPickerHistory = defaults.stringArray(forKey: Keys.colorPickerHistory) ?? []
        brightnessKeyTarget = defaults.string(forKey: Keys.brightnessKeyTarget)
            .flatMap(BrightnessKeyTarget.init(rawValue:)) ?? .underCursor
        brightnessKeySelectedDisplayUUIDs = Set(defaults.stringArray(forKey: Keys.brightnessKeySelected) ?? [])
        hidpiShortcut = defaults.data(forKey: Keys.hidpiShortcut)
            .flatMap { try? JSONDecoder().decode(KeyboardShortcut.self, from: $0) }
    }
}
