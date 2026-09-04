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

    init(
        id: UInt32,
        name: String,
        brightness: Double,
        maxBrightness: Double? = nil,
        isBuiltin: Bool,
        uuid: String? = nil,
        resolution: CrispControlResolution? = nil,
        brightnessBackend: CrispControlBrightnessBackend? = nil
    ) {
        self.id = id
        self.name = name
        self.brightness = brightness
        self.maxBrightness = maxBrightness
        self.isBuiltin = isBuiltin
        self.uuid = uuid
        self.resolution = resolution
        self.brightnessBackend = brightnessBackend
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
    }

    let command: Command
    let display: UInt32?
    let brightness: Double?
    /// A display as a person typed it: a runtime id or a uuid. Takes precedence over
    /// `display`, which stays for clients that already send the numeric id.
    let selector: String?
    let enabled: Bool?
    init(
        command: Command,
        display: UInt32? = nil,
        brightness: Double? = nil,
        selector: String? = nil,
        enabled: Bool? = nil
    ) {
        self.command = command
        self.display = display
        self.brightness = brightness
        self.selector = selector
        self.enabled = enabled
    }
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
    let error: String?

    init(
        ok: Bool,
        displays: [CrispControlDisplay]? = nil,
        display: CrispControlDisplay? = nil,
        brightnessBoost: CrispControlBrightnessBoostState? = nil,
        hdr: CrispControlHDRState? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.displays = displays
        self.display = display
        self.brightnessBoost = brightnessBoost
        self.hdr = hdr
        self.error = error
    }
    static func success() -> Self { Self(ok: true) }
    static func success(displays: [CrispControlDisplay]) -> Self { Self(ok: true, displays: displays) }
    static func success(display: CrispControlDisplay) -> Self { Self(ok: true, display: display) }
    static func success(brightnessBoost: CrispControlBrightnessBoostState) -> Self {
        Self(ok: true, brightnessBoost: brightnessBoost)
    }
    static func success(hdr: CrispControlHDRState) -> Self { Self(ok: true, hdr: hdr) }
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
struct CrispControlResult {
    let response: CrispControlResponse
    let brightnessChange: CrispControlBrightnessChange?
    let brightnessBoostChange: CrispControlBrightnessBoostChange?
    let hdrChange: CrispControlHDRChange?

    init(
        _ response: CrispControlResponse,
        _ brightnessChange: CrispControlBrightnessChange?,
        _ brightnessBoostChange: CrispControlBrightnessBoostChange?,
        _ hdrChange: CrispControlHDRChange?
    ) {
        self.response = response
        self.brightnessChange = brightnessChange
        self.brightnessBoostChange = brightnessBoostChange
        self.hdrChange = hdrChange
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
        brightnessBoostState: (UInt32) -> CrispControlBrightnessBoostState? = { _ in nil }
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
        case .getBrightnessBoost:
            guard hasDisplaySelector(request) else {
                return .init(.failure("display is required"), nil, nil, nil)
            }
            guard let display = target(of: request, in: displays),
                  let state = brightnessBoostState(display.id) else {
                return .init(.failure("display not found"), nil, nil, nil)
            }
            return .init(.success(brightnessBoost: state), nil, nil, nil)
        case .setBrightnessBoost:
            guard hasDisplaySelector(request), let enabled = request.enabled else {
                return .init(.failure("display and state are required"), nil, nil, nil)
            }
            guard let display = target(of: request, in: displays) else {
                return .init(.failure("display not found"), nil, nil, nil)
            }
            return .init(.success(), nil, .init(displayID: display.id, enabled: enabled), nil)
        case .getHDR, .setHDR:
            return handleHDR(
                request, displays: displays, hdrState: hdrState,
                hdrMutationUUID: hdrMutationUUID
            )
        }
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
    static let usage = "usage: crispctl <command> [<args>]; run 'crispctl help' for the commands"

    /// The full reference, for a person at a terminal and for an agent that reads it
    /// before acting. Kept in the shared model so the app and the CLI cannot drift.
    static let help = """
        Usage: crispctl <command> [<args>]

        Control a running Crisp from the command line. Crisp must be running for the
        same user; crispctl talks to it over a local socket and never launches it.

        Commands:
          display list                           Online displays as JSON: id, uuid, name,
                                                 resolution, brightness, maxBrightness,
                                                 brightnessBackend
          brightness get <display>               Read logical brightness and its live maximum
          brightness set <display> <pct>         Set 0-100, or up to maxBrightness while Extra
                                                 Brightness is enabled and eligible; clears preset
          brightness boost get <display>         Read Extra Brightness eligibility and state
          brightness boost set <display> on|off  Enable or disable Extra Brightness
          hdr get <display>                      Read live HDR state for an eligible external display
          hdr set <display> on|off               Set HDR on an eligible external and verify live state
          help                                   Show this help (also -h, --help)

        <display> is a runtime id or a uuid from 'display list'. Ids can change after
        an unplug or a wake; uuids do not.

        Output is one JSON object per call: {"ok":true,...} or {"ok":false,"error":"..."}.
        Exit codes: 0 ok, 1 Crisp unreachable, 2 bad arguments, 3 Crisp refused.
        """

    enum ParseResult: Equatable {
        case request(CrispControlRequest)
        case help
        case failure
    }
    enum ResponseResult: Equatable { case success, serverFailure, invalid }
    static func receiveTimeoutSeconds(for command: CrispControlRequest.Command) -> Int {
        switch command {
        case .setBrightnessBoost: return 5
        case .setHDR: return 6
        default: return 2
        }
    }
    static func parse(arguments: [String]) -> ParseResult {
        if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            return .help
        }
        if arguments == ["display", "list"] {
            return .request(.init(command: .list))
        }
        if arguments.count == 3, arguments[0...1] == ["brightness", "get"], !arguments[2].isEmpty {
            return .request(.init(command: .getBrightness, selector: arguments[2]))
        }
        if arguments.count == 4, arguments[0...1] == ["brightness", "set"], !arguments[2].isEmpty,
           let value = Double(arguments[3]), value.isFinite, value >= 0 {
            return .request(.init(command: .setBrightness, brightness: value, selector: arguments[2]))
        }
        if arguments.count == 4, arguments[0...2] == ["brightness", "boost", "get"],
           !arguments[3].isEmpty {
            return .request(.init(command: .getBrightnessBoost, selector: arguments[3]))
        }
        if arguments.count == 5, arguments[0...2] == ["brightness", "boost", "set"],
           !arguments[3].isEmpty {
            switch arguments[4] {
            case "on": return .request(.init(command: .setBrightnessBoost, selector: arguments[3], enabled: true))
            case "off": return .request(.init(command: .setBrightnessBoost, selector: arguments[3], enabled: false))
            default: break
            }
        }
        if arguments.count == 3, arguments[0...1] == ["hdr", "get"], !arguments[2].isEmpty {
            return .request(.init(command: .getHDR, selector: arguments[2]))
        }
        if arguments.count == 4, arguments[0...1] == ["hdr", "set"], !arguments[2].isEmpty {
            switch arguments[3] {
            case "on": return .request(.init(command: .setHDR, selector: arguments[2], enabled: true))
            case "off": return .request(.init(command: .setHDR, selector: arguments[2], enabled: false))
            default: break
            }
        }
        return .failure
    }
    static func classify(_ data: Data, for _: CrispControlRequest.Command) -> ResponseResult {
        guard let response = try? JSONDecoder().decode(CrispControlResponse.self, from: data) else {
            return .invalid
        }
        if response.ok { return .success }
        return response.error != nil ? .serverFailure : .invalid
    }
}
