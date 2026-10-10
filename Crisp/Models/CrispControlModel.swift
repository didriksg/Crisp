import Foundation

enum CrispControlSocket {
    static let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("crispctl.sock").path
}
struct CrispControlResolution: Codable, Equatable {
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool
}
enum CrispControlBrightnessBackend: String, Codable, Equatable {
    case builtin
    case ddc
    case software
    case unknown
}
struct CrispControlDisplay: Codable, Equatable {
    let id: UInt32
    let name: String
    let brightness: Double
    let maxBrightness: Double?
    let isBuiltin: Bool
    let uuid: String?
    let resolution: CrispControlResolution?
    let brightnessBackend: CrispControlBrightnessBackend?
    /// False while Crisp holds the display disconnected. Such a display is absent
    /// from every macOS display list, so its `id` is only the last-known value and
    /// `uuid` is the selector that finds it again. Absent from replies of older Crisps.
    let connected: Bool?

    init(
        id: UInt32,
        name: String,
        brightness: Double,
        maxBrightness: Double? = nil,
        isBuiltin: Bool,
        uuid: String? = nil,
        resolution: CrispControlResolution? = nil,
        brightnessBackend: CrispControlBrightnessBackend? = nil,
        connected: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.brightness = brightness
        self.maxBrightness = maxBrightness
        self.isBuiltin = isBuiltin
        self.uuid = uuid
        self.resolution = resolution
        self.brightnessBackend = brightnessBackend
        self.connected = connected
    }
}
struct CrispControlBrightnessBoostState: Codable, Equatable {
    let displayID: UInt32
    let eligible: Bool
    let enabled: Bool
}
struct CrispControlHDRState: Codable, Equatable {
    let displayID: UInt32
    let enabled: Bool
}
struct CrispControlRequest: Codable, Equatable {
    enum Command: String, Codable {
        case list
        case getBrightness
        case setBrightness
        case getBrightnessBoost
        case setBrightnessBoost
        case getHDR
        case setHDR
        case connectDisplay
        case disconnectDisplay
        case toggleDisplay
        case listPresets
        case applyPreset
        case getImage
        case setImage
        case resetImage
        case listInputs
        case setInput
    }

    let command: Command
    let display: UInt32?
    let brightness: Double?
    /// A display as a person typed it: a runtime id or a uuid. Takes precedence over
    /// `display`, which stays for clients that already send the numeric id. For
    /// `applyPreset`, the preset's id or name.
    let selector: String?
    let enabled: Bool?
    /// `setImage`: which setting, and its new value (invert: 0 or 1).
    let setting: CrispControlImageSetting?
    let value: Double?
    /// `setInput`: the input as a person typed it, a name or a number.
    let input: String?
    init(
        command: Command,
        display: UInt32? = nil,
        brightness: Double? = nil,
        selector: String? = nil,
        enabled: Bool? = nil,
        setting: CrispControlImageSetting? = nil,
        value: Double? = nil,
        input: String? = nil
    ) {
        self.command = command
        self.display = display
        self.brightness = brightness
        self.selector = selector
        self.enabled = enabled
        self.setting = setting
        self.value = value
        self.input = input
    }
}
/// One input of a monitor (#196): the VCP 0x60 value and its connector name.
struct CrispControlInput: Codable, Equatable {
    let value: Int
    let name: String
}
/// A display's inputs as crispctl lists them. `current` is the input this Mac is on,
/// nil when Crisp cannot read it and nobody chose it in the menu.
struct CrispControlInputs: Codable, Equatable {
    let displayID: UInt32
    let uuid: String
    let current: Int?
    let inputs: [CrispControlInput]
}
struct CrispControlInputChange: Equatable {
    let displayID: UInt32
    let input: String
}
/// A saved preset as crispctl lists it. `captures` names what applying it changes
/// (resolution, brightness, arrangement, imageAdjustment, hdr); `displays` are the uuids it
/// has settings for; `active` is true for the preset last applied until a manual change.
struct CrispControlPreset: Codable, Equatable {
    let id: String
    let name: String
    let captures: [String]
    let displays: [String]
    let active: Bool
}
/// One Image Adjustment slider or switch as crispctl names it.
enum CrispControlImageSetting: String, CaseIterable, Codable {
    case contrast, gamma, gain, temperature
    case redGamma = "red-gamma", greenGamma = "green-gamma", blueGamma = "blue-gamma"
    case redGain = "red-gain", greenGain = "green-gain", blueGain = "blue-gain"
    case quantization, invert

    /// The slider's range; invert is 0 (off) or 1 (on).
    var range: ClosedRange<Double> {
        switch self {
        case .quantization: return 2...256
        case .invert: return 0...1
        default: return -100...100
        }
    }
}
/// A display's Image Adjustment as crispctl reports it. `paused` is read-only: Pause in
/// the menu shows the display without the adjustment but keeps the values.
struct CrispControlImageAdjustment: Codable, Equatable {
    let displayID: UInt32
    let uuid: String
    let name: String
    let contrast: Double
    let gamma: Double
    let gain: Double
    let temperature: Double
    let redGamma: Double
    let greenGamma: Double
    let blueGamma: Double
    let redGain: Double
    let greenGain: Double
    let blueGain: Double
    let quantization: Int
    let invert: Bool
    let paused: Bool
}
/// An image set (one setting to a value) or a reset (setting nil) for one display.
struct CrispControlImageChange: Equatable {
    let displayID: UInt32
    let setting: CrispControlImageSetting?
    let value: Double
}
enum CrispControlFrame {
    enum Result: Equatable {
        case incomplete
        case frame(Data)
        case failure(String)
    }

    static func parse(_ data: Data, maximumBytes: Int, endOfStream: Bool) -> Result {
        if let newline = data.firstIndex(of: 0x0A) {
            guard newline < maximumBytes else { return .failure("frame too large") }
            return .frame(Data(data[...newline]))
        }
        guard data.count < maximumBytes else { return .failure("frame too large") }
        return endOfStream ? .failure("frame must end with newline") : .incomplete
    }
}
struct CrispControlResponse: Codable, Equatable {
    let ok: Bool
    let displays: [CrispControlDisplay]?
    let display: CrispControlDisplay?
    let brightnessBoost: CrispControlBrightnessBoostState?
    let hdr: CrispControlHDRState?
    let presets: [CrispControlPreset]?
    let preset: CrispControlPreset?
    /// `applyPreset`: uuids of the preset's displays that were not connected, so nothing
    /// was applied to them.
    let skippedDisplays: [String]?
    let image: CrispControlImageAdjustment?
    let inputs: CrispControlInputs?
    let error: String?

    init(
        ok: Bool,
        displays: [CrispControlDisplay]? = nil,
        display: CrispControlDisplay? = nil,
        brightnessBoost: CrispControlBrightnessBoostState? = nil,
        hdr: CrispControlHDRState? = nil,
        presets: [CrispControlPreset]? = nil,
        preset: CrispControlPreset? = nil,
        skippedDisplays: [String]? = nil,
        image: CrispControlImageAdjustment? = nil,
        inputs: CrispControlInputs? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.displays = displays
        self.display = display
        self.brightnessBoost = brightnessBoost
        self.hdr = hdr
        self.presets = presets
        self.preset = preset
        self.skippedDisplays = skippedDisplays
        self.image = image
        self.inputs = inputs
        self.error = error
    }
    static func success() -> Self { Self(ok: true) }
    static func success(displays: [CrispControlDisplay]) -> Self { Self(ok: true, displays: displays) }
    static func success(display: CrispControlDisplay) -> Self { Self(ok: true, display: display) }
    static func success(brightnessBoost: CrispControlBrightnessBoostState) -> Self {
        Self(ok: true, brightnessBoost: brightnessBoost)
    }
    static func success(hdr: CrispControlHDRState) -> Self { Self(ok: true, hdr: hdr) }
    static func success(presets: [CrispControlPreset]) -> Self { Self(ok: true, presets: presets) }
    static func success(image: CrispControlImageAdjustment) -> Self { Self(ok: true, image: image) }
    static func success(inputs: CrispControlInputs) -> Self { Self(ok: true, inputs: inputs) }
    static func success(preset: CrispControlPreset, skippedDisplays: [String]) -> Self {
        Self(ok: true, preset: preset, skippedDisplays: skippedDisplays)
    }
    static func failure(_ error: String) -> Self { Self(ok: false, error: error) }
}
struct CrispControlBrightnessChange: Equatable {
    let displayID: UInt32
    let brightness: Double
}
struct CrispControlBrightnessBoostChange: Equatable {
    let displayID: UInt32
    let enabled: Bool
}
struct CrispControlHDRChange: Equatable {
    let displayID: UInt32
    let displayUUID: String
    let enabled: Bool
}
/// A resolved connect or disconnect. `toggleDisplay` is collapsed into a concrete
/// direction by `handle`, so the server never has to re-read the current state.
struct CrispControlConnectionChange: Equatable {
    let uuid: String
    let connect: Bool
}
struct CrispControlResult {
    let response: CrispControlResponse
    let brightnessChange: CrispControlBrightnessChange?
    let brightnessBoostChange: CrispControlBrightnessBoostChange?
    let hdrChange: CrispControlHDRChange?
    let connectionChange: CrispControlConnectionChange?
    /// The id of the one preset `applyPreset` resolved to.
    let presetToApply: String?
    let imageChange: CrispControlImageChange?
    /// `listInputs`: the display to list, which the server answers once the monitor's
    /// capabilities are read. `setInput`: the switch to make.
    let inputListDisplayID: UInt32?
    let inputChange: CrispControlInputChange?

    init(
        _ response: CrispControlResponse,
        _ brightnessChange: CrispControlBrightnessChange?,
        _ brightnessBoostChange: CrispControlBrightnessBoostChange?,
        _ hdrChange: CrispControlHDRChange?,
        _ connectionChange: CrispControlConnectionChange? = nil,
        presetToApply: String? = nil,
        imageChange: CrispControlImageChange? = nil,
        inputListDisplayID: UInt32? = nil,
        inputChange: CrispControlInputChange? = nil
    ) {
        self.response = response
        self.brightnessChange = brightnessChange
        self.brightnessBoostChange = brightnessBoostChange
        self.hdrChange = hdrChange
        self.connectionChange = connectionChange
        self.presetToApply = presetToApply
        self.imageChange = imageChange
        self.inputListDisplayID = inputListDisplayID
        self.inputChange = inputChange
    }
}
enum CrispControlModel {
    static func brightnessBackend(
        isBuiltin: Bool,
        hdrSoftwareDimming: Bool,
        ddcAvailable: Bool?
    ) -> CrispControlBrightnessBackend {
        if isBuiltin { return .builtin }
        if hdrSoftwareDimming { return .software }
        switch ddcAvailable {
        case true: return .ddc
        case false: return .software
        case nil: return .unknown
        }
    }

    static func encode<T: Encodable>(_ value: T, sorted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        if sorted { encoder.outputFormatting = .sortedKeys }
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
    static func encode(_ response: CrispControlResponse) -> Data {
        (try? encode(response, sorted: false))
            ?? Data(#"{"ok":false,"error":"response encoding failed"}"#.utf8) + Data([0x0A])
    }
    static func brightnessBoostSetResponse(enabled: Bool, accepted: Bool) -> CrispControlResponse {
        accepted ? .success() : .failure("extra brightness could not be \(enabled ? "enabled" : "disabled")")
    }
    static func hdrSetResponse(
        displayID: UInt32, enabled: Bool, accepted: Bool, liveEnabled: Bool?
    ) -> CrispControlResponse {
        guard let liveEnabled else {
            return .failure("HDR live read-back became unavailable; " + hdrUncertainRecovery)
        }
        guard accepted else { return .failure("HDR request was not accepted") }
        guard liveEnabled == enabled else {
            return .failure(
                "HDR request was accepted, but live read-back did not match before timeout; "
                    + hdrUncertainRecovery
            )
        }
        return .success(hdr: .init(displayID: displayID, enabled: enabled))
    }
    static let hdrUncertainRecovery = "outcome is uncertain; do not retry automatically—run "
        + "'crispctl hdr get <display>' before deciding whether to retry"

    static func handle(
        _ data: Data,
        displays: [CrispControlDisplay],
        hdrState: (UInt32) -> CrispControlHDRState? = { _ in nil },
        hdrMutationUUID: (UInt32) -> String? = { _ in nil },
        brightnessBoostState: (UInt32) -> CrispControlBrightnessBoostState? = { _ in nil },
        presets: [CrispControlPreset] = [],
        imageAdjustment: (UInt32) -> CrispControlImageAdjustment? = { _ in nil }
    ) -> CrispControlResult {
        guard let request = try? JSONDecoder().decode(CrispControlRequest.self, from: data) else {
            return .init(.failure("invalid request"), nil, nil, nil)
        }
        switch request.command {
        case .list:
            return .init(.success(displays: displays), nil, nil, nil)
        case .getBrightness:
            guard hasDisplaySelector(request) else {
                return .init(.failure("display is required"), nil, nil, nil)
            }
            guard let display = target(of: request, in: displays) else {
                return .init(.failure("display not found"), nil, nil, nil)
            }
            return .init(.success(display: display), nil, nil, nil)
        case .setBrightness:
            return handleSetBrightness(request, displays: displays, brightnessBoostState: brightnessBoostState)
        case .getBrightnessBoost, .setBrightnessBoost:
            return handleBrightnessBoost(request, displays: displays, brightnessBoostState: brightnessBoostState)
        case .getHDR, .setHDR:
            return handleHDR(
                request, displays: displays, hdrState: hdrState,
                hdrMutationUUID: hdrMutationUUID
            )
        case .connectDisplay, .disconnectDisplay, .toggleDisplay:
            return handleConnection(request, displays: displays)
        case .listPresets, .applyPreset:
            return handlePreset(request, presets: presets)
        case .getImage, .setImage, .resetImage:
            return handleImage(request, displays: displays, imageAdjustment: imageAdjustment)
        case .listInputs, .setInput:
            return handleInput(request, displays: displays)
        }
    }

    /// Inputs are read and written over the display's DDC channel, which only a
    /// connected external has.
    private static func handleInput(_ request: CrispControlRequest, displays: [CrispControlDisplay]) -> CrispControlResult {
        guard hasDisplaySelector(request) else {
            return .init(.failure("display is required"), nil, nil, nil)
        }
        guard let display = target(of: request, in: displays) else {
            return .init(.failure("display not found"), nil, nil, nil)
        }
        guard !display.isBuiltin else {
            return .init(.failure("the built-in display has no inputs"), nil, nil, nil)
        }
        guard display.connected ?? true else {
            return .init(.failure("display is not connected; 'display connect' switches it back to this Mac"), nil, nil, nil)
        }
        guard request.command == .setInput else {
            return .init(.success(), nil, nil, nil, inputListDisplayID: display.id)
        }
        guard let input = request.input, !input.isEmpty else {
            return .init(.failure("input is required"), nil, nil, nil)
        }
        return .init(.success(), nil, nil, nil, inputChange: .init(displayID: display.id, input: input))
    }

    private static func handleBrightnessBoost(
        _ request: CrispControlRequest,
        displays: [CrispControlDisplay],
        brightnessBoostState: (UInt32) -> CrispControlBrightnessBoostState?
    ) -> CrispControlResult {
        if request.command == .getBrightnessBoost {
            guard hasDisplaySelector(request) else {
                return .init(.failure("display is required"), nil, nil, nil)
            }
            guard let display = target(of: request, in: displays),
                  let state = brightnessBoostState(display.id) else {
                return .init(.failure("display not found"), nil, nil, nil)
            }
            return .init(.success(brightnessBoost: state), nil, nil, nil)
        }
        guard hasDisplaySelector(request), let enabled = request.enabled else {
            return .init(.failure("display and state are required"), nil, nil, nil)
        }
        guard let display = target(of: request, in: displays) else {
            return .init(.failure("display not found"), nil, nil, nil)
        }
        return .init(.success(), nil, .init(displayID: display.id, enabled: enabled), nil)
    }

    /// Image Adjustment lives in the display's gamma table, so only a connected display
    /// has one to read or set. Values outside a setting's range are refused, not clamped.
    private static func handleImage(
        _ request: CrispControlRequest,
        displays: [CrispControlDisplay],
        imageAdjustment: (UInt32) -> CrispControlImageAdjustment?
    ) -> CrispControlResult {
        guard hasDisplaySelector(request) else {
            return .init(.failure("display is required"), nil, nil, nil)
        }
        guard let display = target(of: request, in: displays) else {
            return .init(.failure("display not found"), nil, nil, nil)
        }
        guard display.connected ?? true, let current = imageAdjustment(display.id) else {
            return .init(.failure("display is not connected"), nil, nil, nil)
        }
        switch request.command {
        case .getImage:
            return .init(.success(image: current), nil, nil, nil)
        case .resetImage:
            return .init(.success(), nil, nil, nil, imageChange: .init(displayID: display.id, setting: nil, value: 0))
        default:
            guard let setting = request.setting, let value = request.value else {
                return .init(.failure("setting and value are required"), nil, nil, nil)
            }
            guard value.isFinite, setting.range.contains(value),
                  setting != .quantization || value.rounded() == value else {
                let range = setting == .invert ? "on or off"
                    : "\(Int(setting.range.lowerBound)) to \(Int(setting.range.upperBound))"
                return .init(.failure("\(setting.rawValue) must be \(range)"), nil, nil, nil)
            }
            return .init(.success(), nil, nil, nil, imageChange: .init(displayID: display.id, setting: setting, value: value))
        }
    }

    private static func handlePreset(_ request: CrispControlRequest, presets: [CrispControlPreset]) -> CrispControlResult {
        guard request.command == .applyPreset else { return .init(.success(presets: presets), nil, nil, nil) }
        guard let selector = request.selector, !selector.isEmpty else {
            return .init(.failure("preset is required"), nil, nil, nil)
        }
        switch resolve(preset: selector, in: presets) {
        case .success(let preset): return .init(.success(), nil, nil, nil, presetToApply: preset.id)
        case .failure(let error): return .init(.failure(error.message), nil, nil, nil)
        }
    }

    struct PresetSelectorError: Error { let message: String }

    /// Finds a preset by the selector a person typed: its id, else its name in any case.
    /// A name two presets share is refused, since applying either could be wrong.
    static func resolve(preset selector: String, in presets: [CrispControlPreset]) -> Result<CrispControlPreset, PresetSelectorError> {
        if let match = presets.first(where: { $0.id.caseInsensitiveCompare(selector) == .orderedSame }) {
            return .success(match)
        }
        let named = presets.filter { $0.name.caseInsensitiveCompare(selector) == .orderedSame }
        if named.count == 1 { return .success(named[0]) }
        if named.count > 1 {
            let ids = named.map(\.id).joined(separator: ", ")
            return .failure(.init(message: "\(named.count) presets are named '\(selector)'; use an id: \(ids)"))
        }
        let names = presets.isEmpty ? "none saved" : presets.map(\.name).joined(separator: ", ")
        return .failure(.init(message: "no preset named '\(selector)'; presets: \(names)"))
    }

    /// Resolves a connection request against the online list plus the displays Crisp
    /// is holding disconnected. Asking for the state a display is already in succeeds
    /// and changes nothing, so a button wired to `connect` or `disconnect` is safe to
    /// press twice.
    private static func handleConnection(
        _ request: CrispControlRequest, displays: [CrispControlDisplay]
    ) -> CrispControlResult {
        guard hasDisplaySelector(request) else {
            return .init(.failure("display is required"), nil, nil, nil)
        }
        guard let display = target(of: request, in: displays) else {
            return .init(.failure("display not found"), nil, nil, nil)
        }
        // A display with no stable uuid cannot be found again once it is gone, so
        // refuse rather than hand back a handle that will not work.
        guard let uuid = display.uuid, !uuid.isEmpty else {
            return .init(.failure("display has no stable uuid, so it could not be reconnected"), nil, nil, nil)
        }
        let connected = display.connected ?? true
        let connect: Bool
        switch request.command {
        case .connectDisplay: connect = true
        case .disconnectDisplay: connect = false
        default: connect = !connected
        }
        let settled = CrispControlDisplay(
            id: display.id, name: display.name, brightness: display.brightness,
            maxBrightness: display.maxBrightness, isBuiltin: display.isBuiltin, uuid: uuid,
            resolution: display.resolution, brightnessBackend: display.brightnessBackend,
            connected: connect
        )
        let change = connected == connect ? nil : CrispControlConnectionChange(uuid: uuid, connect: connect)
        return .init(.success(display: settled), nil, nil, nil, change)
    }

    private static func handleHDR(
        _ request: CrispControlRequest,
        displays: [CrispControlDisplay],
        hdrState: (UInt32) -> CrispControlHDRState?,
        hdrMutationUUID: (UInt32) -> String?
    ) -> CrispControlResult {
        guard hasDisplaySelector(request) else {
            return .init(.failure("display is required"), nil, nil, nil)
        }
        guard let display = target(of: request, in: displays) else {
            return .init(.failure("display not found"), nil, nil, nil)
        }
        guard !display.isBuiltin else {
            return .init(
                .failure(
                    "explicit HDR is unsupported for built-in displays; use Extra Brightness "
                        + "with 'crispctl brightness boost set <display> on' when eligible"
                ), nil, nil, nil
            )
        }
        guard let state = hdrState(display.id) else {
            return .init(.failure("explicit HDR is unsupported for this external display"), nil, nil, nil)
        }
        if request.command == .getHDR {
            return .init(.success(hdr: state), nil, nil, nil)
        }
        guard let enabled = request.enabled else {
            return .init(.failure("display and state are required"), nil, nil, nil)
        }
        guard let uuid = hdrMutationUUID(display.id), !uuid.isEmpty else {
            return .init(.failure("unique live display identity is unavailable"), nil, nil, nil)
        }
        if let selector = request.selector, UInt32(selector) == nil,
           selector.caseInsensitiveCompare(uuid) != .orderedSame {
            return .init(.failure("unique live display identity does not match selector"), nil, nil, nil)
        }
        return .init(
            .success(), nil, nil,
            .init(displayID: display.id, displayUUID: uuid, enabled: enabled)
        )
    }

    private static func handleSetBrightness(
        _ request: CrispControlRequest,
        displays: [CrispControlDisplay],
        brightnessBoostState: (UInt32) -> CrispControlBrightnessBoostState?
    ) -> CrispControlResult {
        guard hasDisplaySelector(request), let value = request.brightness else {
            return .init(.failure("display and brightness are required"), nil, nil, nil)
        }
        guard value.isFinite, value >= 0 else {
            return .init(.failure("brightness must be finite and nonnegative"), nil, nil, nil)
        }
        guard let display = target(of: request, in: displays) else {
            return .init(.failure("display not found"), nil, nil, nil)
        }
        if value > 100 {
            guard let state = brightnessBoostState(display.id), state.enabled else {
                return .init(.failure("extra brightness is disabled for this display"), nil, nil, nil)
            }
            guard state.eligible else {
                return .init(.failure("extra brightness is not eligible for this display"), nil, nil, nil)
            }
            guard let maximum = display.maxBrightness else {
                return .init(.failure("extra brightness maximum is unavailable for this display"), nil, nil, nil)
            }
            guard value <= maximum else {
                return .init(.failure("brightness exceeds the live maximum of \(maximum)"), nil, nil, nil)
            }
        }
        return .init(.success(), .init(displayID: display.id, brightness: value), nil, nil)
    }

    /// Finds a display by the selector a person typed: a runtime id, or a uuid in any
    /// case. Ids win, so a uuid that happens to be all digits still needs the uuid form.
    static func resolve(selector: String, in displays: [CrispControlDisplay]) -> CrispControlDisplay? {
        if let id = UInt32(selector), let match = displays.first(where: { $0.id == id }) {
            return match
        }
        return displays.first { $0.uuid?.caseInsensitiveCompare(selector) == .orderedSame }
    }
    private static func target(
        of request: CrispControlRequest, in displays: [CrispControlDisplay]
    ) -> CrispControlDisplay? {
        if let selector = request.selector { return resolve(selector: selector, in: displays) }
        return request.display.flatMap { id in displays.first { $0.id == id } }
    }
    private static func hasDisplaySelector(_ request: CrispControlRequest) -> Bool {
        request.selector != nil || request.display != nil
    }
}
enum CrispControlCLIModel {
    enum Group: String, CaseIterable {
        case display, brightness, hdr, image, preset
        var title: String {
            switch self {
            case .display: return "Display commands"
            case .brightness: return "Brightness commands"
            case .hdr: return "HDR commands"
            case .image: return "Image Adjustment commands"
            case .preset: return "Preset commands"
            }
        }
        var description: String {
            switch self {
            case .display: return "List, connect and disconnect the displays Crisp controls, and switch their inputs."
            case .brightness: return "Read and set brightness and Extra Brightness."
            case .hdr: return "Read and switch HDR on external displays."
            case .image: return "Read and set Image Adjustment: contrast, gamma, color temperature and the other sliders."
            case .preset: return "List and apply the presets saved in Crisp."
            }
        }
    }

    /// One documented command: the usage as typed, a one-line summary for the tables,
    /// and the detail its own help page prints. Kept in the shared model so the app
    /// and the CLI cannot drift.
    struct Entry: Equatable {
        let group: Group
        let usage: String
        let summary: String
        let detail: String
        /// The usage without the group: "toggle <display>" on the group's page.
        var subcommand: String { String(usage.drop { $0 != " " }.dropFirst()) }
        /// The usage split at the first placeholder: ("display toggle", "<display>").
        var columns: (command: String, arguments: String) {
            let parts = usage.split(separator: " ").map(String.init)
            let command = parts.prefix { !$0.hasPrefix("<") }
            return (command.joined(separator: " "), parts.dropFirst(command.count).joined(separator: " "))
        }
        /// The literal words before the first placeholder ("display toggle" for
        /// "display toggle <display>"): what an invocation is matched on.
        var words: [String] {
            Array(usage.split(separator: " ").map(String.init).prefix { !$0.hasPrefix("<") })
        }
    }

    static let entries: [Entry] = [
        Entry(group: .display, usage: "display list", summary: "List displays as JSON", detail: """
            Each display carries id, uuid, name, resolution, brightness, maxBrightness,
            brightnessBackend and connected, which is false while Crisp holds it off.
            """),
        Entry(group: .display, usage: "display connect <display>", summary: "Put a disconnected display back", detail: """
            Asking for the state a display is already in succeeds and changes nothing.
            The reply comes after the window server has answered.
            """),
        Entry(group: .display, usage: "display disconnect <display>", summary: "Take a display out of the layout", detail: """
            The same as Disconnect Display in the menu; refused if it would leave no
            active display. Apple Silicon only. Asking for the state a display is
            already in succeeds and changes nothing. The reply comes after the window
            server has answered.
            """),
        Entry(group: .display, usage: "display toggle <display>", summary: "Disconnect if connected, connect if not", detail: """
            The reply comes after the window server has answered. If it is lost, run
            'display list' before retrying: the display may already have changed state.
            """),
        Entry(group: .display, usage: "display input list <display>", summary: "List a monitor's inputs as JSON", detail: """
            Each input carries value and name, from the list the monitor reports, or a
            standard list when it reports none. current is the input this Mac is on, or
            null when Crisp cannot read it. The first call for a monitor reads its list,
            which can take half a minute.
            """),
        Entry(group: .display, usage: "display input set <display> <input>", summary: "Switch a monitor to another input", detail: """
            <input> is a name (HDMI 1, hdmi1, dp2, usb-c) or a number, decimal (17) or
            hex (0x11). The same as choosing it in the menu: the display is then
            disconnected, and 'display connect' switches it back to this Mac. On the last
            active display it switches without the disconnect. The reply comes after the
            window server has answered.
            """),
        Entry(group: .brightness, usage: "brightness get <display>", summary: "Read brightness and its live maximum", detail: ""),
        Entry(group: .brightness, usage: "brightness set <display> <percent>", summary: "Set brightness", detail: """
            <percent> is 0-100, or up to maxBrightness while Extra Brightness is enabled
            and eligible; boosted values past the live maximum are refused, not clamped.
            A set is a manual change like the slider and clears the active preset. The
            reply means Crisp accepted the request, not that the panel was read back.
            """),
        Entry(group: .brightness, usage: "brightness boost get <display>", summary: "Read Extra Brightness state",
              detail: "Whether the display is eligible for Extra Brightness and whether it is on."),
        Entry(group: .brightness, usage: "brightness boost set <display> on|off", summary: "Switch Extra Brightness", detail: ""),
        Entry(group: .hdr, usage: "hdr get <display>", summary: "Read HDR state",
              detail: "The live state of an eligible external display."),
        Entry(group: .hdr, usage: "hdr set <display> on|off", summary: "Switch HDR on an eligible external", detail: """
            Verified against the live state after the switch. If the reply is lost, do not
            retry automatically: run 'hdr get' first.
            """),
        Entry(group: .image, usage: "image get <display>", summary: "Read Image Adjustment as JSON", detail: """
            The display's id, uuid and name, the values of every setting 'image set' takes,
            and paused, which is true while Pause in the menu shows the display without its
            adjustment. 'image set' and 'image reset' reply with the same object.
            """),
        Entry(group: .image, usage: "image set <display> <setting> <value>", summary: "Set one Image Adjustment value", detail: """
            The same as moving that slider in the menu: applied, saved, and it clears the
            active preset. <setting> is contrast, gamma, gain, temperature, red-gamma,
            green-gamma, blue-gamma, red-gain, green-gain or blue-gain (-100 to 100, 0 is
            neutral; temperature -100 is 2000 K, 100 is 12000 K), quantization (2 to 256,
            256 is off) or invert (on or off). Values out of range are refused, not
            clamped. The display must be connected.
            """),
        Entry(group: .image, usage: "image reset <display>", summary: "Reset Image Adjustment to neutral",
              detail: "The same as Reset All in the menu."),
        Entry(group: .preset, usage: "preset list", summary: "List presets as JSON", detail: """
            Each preset carries id, name, captures (what applying it changes: resolution,
            brightness, arrangement, imageAdjustment, hdr, connection), displays (the uuids it has
            settings for) and active, which is true for the preset last applied until a
            manual change.
            """),
        Entry(group: .preset, usage: "preset apply <preset>", summary: "Apply a preset", detail: """
            <preset> is an id or a name from 'preset list'. Names match in any case; a name
            two presets share is refused, so use the id. The same as clicking the preset in
            the menu. The reply comes after it is applied; skippedDisplays lists the
            preset's displays that were not connected. Refused while another preset is
            being applied.
            """)
    ]
    static let otherRows: [(usage: String, arguments: String, summary: String)] = [
        ("help", "", "Show this help (also -h, --help)"),
        ("version", "", "Show the Crisp version this tool ships with (also --version)"),
        ("skill show", "", "Print the agent skill for crispctl"),
        ("skill install", "claude|codex", "Install that skill for Claude Code or Codex")
    ]

    static let intro = """
        Control a running Crisp from the command line. Crisp must be running for the
        same user; crispctl talks to it over a local socket and never launches it.
        """
    static let displayNote = """
        <display> is a runtime id or a uuid from 'display list'. Ids can change after
        an unplug or a wake; uuids do not. A disconnected display is gone from every
        macOS display list, so use its uuid.
        """
    static let contract = """
        Output is one JSON object per call: {"ok":true,...} or {"ok":false,"error":"..."}.
        Exit codes: 0 ok, 1 Crisp unreachable, 2 bad arguments, 3 Crisp refused.
        """

    /// The top-level reference: one line per command, the way docker and gh lay
    /// theirs out. The detail lives on the group and command pages.
    static let help: String = {
        var lines = [intro, "", "Usage:  crispctl <command> <subcommand> [<args>]", ""]
        let widths = columnWidths(entries.map(\.columns) + otherRows.map { ($0.usage, $0.arguments) })
        for group in Group.allCases {
            lines.append(group.title + ":")
            for entry in entries where entry.group == group { lines.append(row(entry.columns, entry.summary, widths)) }
            lines.append("")
        }
        lines.append("Other commands:")
        for other in otherRows { lines.append(row((other.usage, other.arguments), other.summary, widths)) }
        lines += ["", displayNote, "", contract, "", "Run 'crispctl <command> --help' for more information on a command."]
        return lines.joined(separator: "\n")
    }()

    /// One group's page, printed for `crispctl display`, `crispctl display help`
    /// and `crispctl display --help`: what `docker container --help` prints.
    static func help(for group: Group) -> String {
        let inGroup = entries.filter { $0.group == group }
        let rows = inGroup.map { entry -> (command: String, arguments: String) in
            let columns = entry.columns
            return (String(columns.command.dropFirst(group.rawValue.count + 1)), columns.arguments)
        }
        let widths = columnWidths(rows)
        var lines = [group.description, "", "Usage:  crispctl \(group.rawValue) <subcommand> [<args>]", "", "Commands:"]
        lines += zip(rows, inGroup).map { row($0, $1.summary, widths) }
        lines += ["", "Run 'crispctl \(group.rawValue) <subcommand> --help' for more information on a command."]
        return lines.joined(separator: "\n")
    }

    /// One command's page, printed for any invocation of it that ends in --help or -h.
    static func help(for entry: Entry) -> String {
        var lines = ["Usage:  crispctl \(entry.usage)", "", entry.summary + "."]
        if !entry.detail.isEmpty { lines += ["", entry.detail] }
        return lines.joined(separator: "\n")
    }

    /// Three aligned columns: command, its arguments, what it does. An empty
    /// argument column collapses so a table without arguments has no gap.
    private static func columnWidths(_ rows: [(command: String, arguments: String)]) -> (Int, Int) {
        let arguments = rows.map(\.arguments.count).max()!
        return (1 + rows.map(\.command.count).max()!, arguments == 0 ? 0 : 2 + arguments)
    }
    private static func row(_ columns: (command: String, arguments: String), _ summary: String, _ widths: (Int, Int)) -> String {
        "  " + columns.command.padding(toLength: widths.0, withPad: " ", startingAt: 0)
            + columns.arguments.padding(toLength: widths.1, withPad: " ", startingAt: 0) + summary
    }

    enum HelpTopic: Equatable {
        case all
        case group(Group)
        case command(Entry)
    }
    enum ParseResult: Equatable {
        case request(CrispControlRequest)
        case help(HelpTopic)
        case version
        case showSkill
        case installSkill(agent: String)
        case failure(String)
    }
    enum ResponseResult: Equatable { case success, serverFailure, invalid }
    static func receiveTimeoutSeconds(for command: CrispControlRequest.Command) -> Int {
        switch command {
        case .setBrightnessBoost: return 5
        case .setHDR: return 6
        // The window server answers inside the app's 10 s wrapper, but the DDC hold
        // ahead of the transaction can wait 15 s and the mode restore after it 3 s.
        case .connectDisplay, .disconnectDisplay, .toggleDisplay, .setInput: return 30
        // The first list for a monitor reads its capabilities chunk by chunk.
        case .listInputs: return 60
        // A resolution or arrangement change waits for the reconfiguration to land.
        case .applyPreset: return 30
        default: return 2
        }
    }
    static func parse(arguments: [String]) -> ParseResult {
        if let help = helpRequest(arguments) { return help }
        if let skill = skillRequest(arguments) { return skill }
        if let request = matchedRequest(arguments) { return .request(request) }
        return .failure(usageMessage(for: arguments))
    }
    private static func helpRequest(_ arguments: [String]) -> ParseResult? {
        let helpWords: Set<String> = ["help", "--help", "-h"]
        if arguments.isEmpty || (arguments.count == 1 && helpWords.contains(arguments[0])) { return .help(.all) }
        if arguments == ["version"] || arguments == ["--version"] { return .version }
        guard let group = Group(rawValue: arguments[0]) else { return nil }
        if arguments.count == 1 || (arguments.count == 2 && helpWords.contains(arguments[1])) { return .help(.group(group)) }
        guard let last = arguments.last, last == "--help" || last == "-h" else { return nil }
        // The longest command whose literal words open the invocation gets its own page.
        let opened = entries.filter { $0.group == group && arguments.starts(with: $0.words) }
            .max { $0.words.count < $1.words.count }
        return .help(opened.map(HelpTopic.command) ?? .group(group))
    }
    private static func skillRequest(_ arguments: [String]) -> ParseResult? {
        guard arguments.first == "skill" else { return nil }
        if arguments == ["skill", "show"] { return .showSkill }
        if arguments.count == 3, arguments[1] == "install", skillFolders[arguments[2]] != nil {
            return .installSkill(agent: arguments[2])
        }
        return .failure("usage: crispctl skill show or crispctl skill install claude|codex")
    }
    /// Where each agent reads user skills, relative to the home folder.
    static let skillFolders = ["claude": ".claude/skills", "codex": ".agents/skills"]
    /// What a wrong invocation gets: the usage of the command it was closest to, or,
    /// for a word that is no command at all, where the commands are listed.
    static func usageMessage(for arguments: [String]) -> String {
        guard let first = arguments.first, let group = Group(rawValue: first) else {
            let word = arguments.first.map { "unknown command '\($0)'; " } ?? ""
            return word + "run 'crispctl help' for the commands"
        }
        let inGroup = entries.filter { $0.group == group }
        // The longest command whose literal words open the invocation, else every
        // command the invocation is a prefix of ("brightness boost" names two).
        let opened = inGroup.filter { arguments.starts(with: $0.words) }.max { $0.words.count < $1.words.count }
        let matches = opened.map { [$0] } ?? inGroup.filter { $0.words.starts(with: arguments) }
        guard !matches.isEmpty else {
            let name = arguments.prefix(2).joined(separator: " ")
            return "unknown command '\(name)'; run 'crispctl \(group.rawValue)' for the \(group.rawValue) commands"
        }
        return "usage: " + matches.map { "crispctl " + $0.usage }.joined(separator: " or ")
    }
    private static func matchedRequest(_ arguments: [String]) -> CrispControlRequest? {
        if arguments == ["display", "list"] {
            return .init(command: .list)
        }
        if arguments.count == 3, arguments[0...1] == ["brightness", "get"], !arguments[2].isEmpty {
            return .init(command: .getBrightness, selector: arguments[2])
        }
        if arguments.count == 4, arguments[0...1] == ["brightness", "set"], !arguments[2].isEmpty,
           let value = Double(arguments[3]), value.isFinite, value >= 0 {
            return .init(command: .setBrightness, brightness: value, selector: arguments[2])
        }
        if arguments.count == 4, arguments[0...2] == ["brightness", "boost", "get"],
           !arguments[3].isEmpty {
            return .init(command: .getBrightnessBoost, selector: arguments[3])
        }
        if arguments.count == 5, arguments[0...2] == ["brightness", "boost", "set"],
           !arguments[3].isEmpty {
            switch arguments[4] {
            case "on": return .init(command: .setBrightnessBoost, selector: arguments[3], enabled: true)
            case "off": return .init(command: .setBrightnessBoost, selector: arguments[3], enabled: false)
            default: break
            }
        }
        if arguments.count == 3, arguments[0...1] == ["hdr", "get"], !arguments[2].isEmpty {
            return .init(command: .getHDR, selector: arguments[2])
        }
        if arguments.count == 4, arguments[0...1] == ["hdr", "set"], !arguments[2].isEmpty {
            switch arguments[3] {
            case "on": return .init(command: .setHDR, selector: arguments[2], enabled: true)
            case "off": return .init(command: .setHDR, selector: arguments[2], enabled: false)
            default: break
            }
        }
        return imageRequest(arguments) ?? presetRequest(arguments) ?? connectionRequest(arguments)
    }
    private static func presetRequest(_ arguments: [String]) -> CrispControlRequest? {
        if arguments == ["preset", "list"] { return .init(command: .listPresets) }
        guard arguments.count == 3, arguments[0...1] == ["preset", "apply"], !arguments[2].isEmpty else { return nil }
        return .init(command: .applyPreset, selector: arguments[2])
    }
    private static func imageRequest(_ arguments: [String]) -> CrispControlRequest? {
        guard arguments.first == "image", arguments.count >= 3, !arguments[2].isEmpty else { return nil }
        switch (arguments[1], arguments.count) {
        case ("get", 3): return .init(command: .getImage, selector: arguments[2])
        case ("reset", 3): return .init(command: .resetImage, selector: arguments[2])
        case ("set", 5):
            guard let setting = CrispControlImageSetting(rawValue: arguments[3]) else { return nil }
            let value: Double?
            switch (setting, arguments[4]) {
            case (.invert, "on"): value = 1
            case (.invert, "off"): value = 0
            case (.invert, _): value = nil
            default: value = Double(arguments[4])
            }
            return value.map { .init(command: .setImage, selector: arguments[2], setting: setting, value: $0) }
        default: return nil
        }
    }
    private static func connectionRequest(_ arguments: [String]) -> CrispControlRequest? {
        if arguments.count == 4, arguments[0...2] == ["display", "input", "list"], !arguments[3].isEmpty {
            return .init(command: .listInputs, selector: arguments[3])
        }
        if arguments.count == 5, arguments[0...2] == ["display", "input", "set"], !arguments[3].isEmpty,
           !arguments[4].isEmpty {
            return .init(command: .setInput, selector: arguments[3], input: arguments[4])
        }
        guard arguments.count == 3, arguments[0] == "display", !arguments[2].isEmpty else { return nil }
        switch arguments[1] {
        case "connect": return .init(command: .connectDisplay, selector: arguments[2])
        case "disconnect": return .init(command: .disconnectDisplay, selector: arguments[2])
        case "toggle": return .init(command: .toggleDisplay, selector: arguments[2])
        default: return nil
        }
    }
    static func classify(_ data: Data, for _: CrispControlRequest.Command) -> ResponseResult {
        guard let response = try? JSONDecoder().decode(CrispControlResponse.self, from: data) else {
            return .invalid
        }
        if response.ok { return .success }
        return response.error != nil ? .serverFailure : .invalid
    }
}
