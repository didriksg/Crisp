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
        case powerOffDisplay
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
/// A resolved connect or disconnect. `toggleDisplay` is collapsed into a concrete
/// direction by `handle`, so the server never has to re-read the current state.
struct CrispControlConnectionChange: Equatable {
    let uuid: String
    let connect: Bool
}
/// A resolved `display power off`: one DDC/CI write of VCP D6 asking the monitor to
/// switch itself off. One-way by the MCCS definition of that value (the power button
/// brings it back), so there is no direction field.
struct CrispControlPowerChange: Equatable {
    let displayID: UInt32
}
struct CrispControlResult {
    let response: CrispControlResponse
    let brightnessChange: CrispControlBrightnessChange?
    let brightnessBoostChange: CrispControlBrightnessBoostChange?
    let hdrChange: CrispControlHDRChange?
    let connectionChange: CrispControlConnectionChange?
    let powerChange: CrispControlPowerChange?

    init(
        _ response: CrispControlResponse,
        _ brightnessChange: CrispControlBrightnessChange?,
        _ brightnessBoostChange: CrispControlBrightnessBoostChange?,
        _ hdrChange: CrispControlHDRChange?,
        _ connectionChange: CrispControlConnectionChange? = nil,
        powerChange: CrispControlPowerChange? = nil
    ) {
        self.response = response
        self.brightnessChange = brightnessChange
        self.brightnessBoostChange = brightnessBoostChange
        self.hdrChange = hdrChange
        self.connectionChange = connectionChange
        self.powerChange = powerChange
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
        case .connectDisplay, .disconnectDisplay, .toggleDisplay:
            return handleConnection(request, displays: displays)
        case .powerOffDisplay:
            return handlePowerOff(request, displays: displays)
        }
    }

    /// The built-in has no DDC/CI, and a display Crisp is holding disconnected has no
    /// channel to write to; everything else is the monitor's call.
    private static func handlePowerOff(
        _ request: CrispControlRequest, displays: [CrispControlDisplay]
    ) -> CrispControlResult {
        guard hasDisplaySelector(request) else {
            return .init(.failure("display is required"), nil, nil, nil)
        }
        guard let display = target(of: request, in: displays) else {
            return .init(.failure("display not found"), nil, nil, nil)
        }
        guard !display.isBuiltin else {
            return .init(.failure("the built-in display has no DDC/CI; use display sleep"), nil, nil, nil)
        }
        guard display.connected ?? true else {
            return .init(.failure("display is disconnected, so there is no DDC channel to write to"), nil, nil, nil)
        }
        return .init(.success(), nil, nil, nil, powerChange: .init(displayID: display.id))
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
        case display, brightness, hdr
        var title: String {
            switch self {
            case .display: return "Display commands"
            case .brightness: return "Brightness commands"
            case .hdr: return "HDR commands"
            }
        }
    }

    /// One documented command: the usage as typed, a one-line summary for the
    /// top-level table, and the detail the group's help prints under it. Kept in the
    /// shared model so the app and the CLI cannot drift.
    struct Entry {
        let group: Group
        let usage: String
        let summary: String
        let detail: String
        /// The literal words before the first placeholder ("display power" for
        /// "display power <display> off"): what a wrong invocation is matched on.
        var words: [String] {
            Array(usage.split(separator: " ").map(String.init).prefix { !$0.hasPrefix("<") })
        }
    }

    static let entries: [Entry] = [
        Entry(group: .display, usage: "display list", summary: "List displays as JSON", detail: """
            Each display: id, uuid, name, resolution, brightness, maxBrightness,
            brightnessBackend and connected (false while Crisp holds it off).
            """),
        Entry(group: .display, usage: "display connect <display>", summary: "Put a disconnected display back", detail: ""),
        Entry(group: .display, usage: "display disconnect <display>", summary: "Take a display out of the layout", detail: """
            As the menu's Disconnect Display does; refused if it would leave no active
            display. Apple Silicon only.
            """),
        Entry(group: .display, usage: "display toggle <display>", summary: "Disconnect if connected, connect if not", detail: ""),
        Entry(group: .display, usage: "display power <display> off", summary: "Ask the monitor to switch itself off", detail: """
            One DDC/CI write (VCP D6). One-way: the monitor's DDC/CI goes with it and its
            power button brings it back. Firmware decides whether it is honoured; ok means
            the write was taken.
            """),
        Entry(group: .brightness, usage: "brightness get <display>", summary: "Read brightness and its live maximum", detail: ""),
        Entry(group: .brightness, usage: "brightness set <display> <percent>", summary: "Set brightness", detail: """
            0-100, or up to maxBrightness while Extra Brightness is enabled and eligible;
            boosted values past the live maximum are refused, not clamped. A set is a
            manual change like the slider and clears the active preset. The reply means
            Crisp accepted the request, not that the panel was read back.
            """),
        Entry(group: .brightness, usage: "brightness boost get <display>", summary: "Read Extra Brightness state",
              detail: "Whether the display is eligible and whether it is on."),
        Entry(group: .brightness, usage: "brightness boost set <display> on|off", summary: "Switch Extra Brightness", detail: ""),
        Entry(group: .hdr, usage: "hdr get <display>", summary: "Read HDR state",
              detail: "The live state of an eligible external display."),
        Entry(group: .hdr, usage: "hdr set <display> on|off", summary: "Switch HDR on an eligible external", detail: """
            Verified against the live state after the switch. If the reply is lost, do not
            retry automatically: run 'hdr get' first.
            """)
    ]
    static let otherRows: [(usage: String, summary: String)] = [
        ("help", "Show this help (also -h, --help)"),
        ("version", "Show the Crisp version this tool ships with (also --version)")
    ]

    static let intro = """
        Control a running Crisp from the command line. Crisp must be running for the
        same user; crispctl talks to it over a local socket and never launches it.
        """
    static let displayNote = """
        <display> is a runtime id or a uuid from 'display list'. Ids can change after
        an unplug or a wake; uuids do not. A disconnected display is gone from every
        macOS display list, so its id is only a last-known value: use the uuid for it.
        """
    static let connectionNote = """
        Asking for the connection state a display is already in succeeds and changes
        nothing. A connection reply comes after the window server has answered.
        """
    static let contract = """
        Output is one JSON object per call: {"ok":true,...} or {"ok":false,"error":"..."}.
        Exit codes: 0 ok, 1 Crisp unreachable, 2 bad arguments, 3 Crisp refused.
        """

    /// The top-level reference: one line per command, the way docker and gh lay
    /// theirs out. The detail lives in each group's own help.
    static let help: String = {
        var lines = [intro, "", "Usage:  crispctl <command> <subcommand> [<args>]", ""]
        for group in Group.allCases {
            lines.append(group.title + ":")
            for entry in entries where entry.group == group { lines.append(row(entry.usage, entry.summary)) }
            lines.append("")
        }
        lines.append("Other commands:")
        for other in otherRows { lines.append(row(other.usage, other.summary)) }
        lines += ["", displayNote, contract, "",
                  "Run 'crispctl <command>' for the details of a command group, e.g. 'crispctl display'."]
        return lines.joined(separator: "\n")
    }()

    /// One group's reference, printed for `crispctl display`, `crispctl display help`
    /// and any invocation in the group that ends in --help or -h.
    static func help(for group: Group) -> String {
        var lines = ["Usage:  crispctl \(group.rawValue) <subcommand> [<args>]", "", group.title + ":"]
        for entry in entries where entry.group == group {
            lines.append(row(entry.usage, entry.summary))
            for line in entry.detail.split(separator: "\n") { lines.append("      " + line) }
        }
        lines += ["", displayNote]
        if group == .display { lines.append(connectionNote) }
        lines.append(contract)
        return lines.joined(separator: "\n")
    }

    private static let column = 2 + (entries.map(\.usage.count) + otherRows.map(\.usage.count)).max()!
    private static func row(_ usage: String, _ summary: String) -> String {
        "  " + usage.padding(toLength: column, withPad: " ", startingAt: 0) + summary
    }

    enum ParseResult: Equatable {
        case request(CrispControlRequest)
        case help(Group?)
        case version
        case failure(String)
    }
    enum ResponseResult: Equatable { case success, serverFailure, invalid }
    static func receiveTimeoutSeconds(for command: CrispControlRequest.Command) -> Int {
        switch command {
        case .setBrightnessBoost: return 5
        case .setHDR: return 6
        // The window server answers inside the app's 10 s wrapper, but the DDC hold
        // ahead of the transaction can wait 15 s and the mode restore after it 3 s.
        case .connectDisplay, .disconnectDisplay, .toggleDisplay: return 30
        // Three write attempts, each able to sit on a wedged channel for the 6 s I2C timeout.
        case .powerOffDisplay: return 20
        default: return 2
        }
    }
    static func parse(arguments: [String]) -> ParseResult {
        if let help = helpRequest(arguments) { return help }
        if let request = matchedRequest(arguments) { return .request(request) }
        return .failure(usageMessage(for: arguments))
    }
    private static func helpRequest(_ arguments: [String]) -> ParseResult? {
        let helpWords: Set<String> = ["help", "--help", "-h"]
        if arguments.isEmpty || (arguments.count == 1 && helpWords.contains(arguments[0])) { return .help(nil) }
        if arguments == ["version"] || arguments == ["--version"] { return .version }
        guard let group = Group(rawValue: arguments[0]) else { return nil }
        if arguments.count == 1 || helpWords.contains(arguments[1]) || arguments.last == "--help" || arguments.last == "-h" {
            return .help(group)
        }
        return nil
    }
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
        if arguments.count == 4, arguments[0...1] == ["display", "power"], !arguments[2].isEmpty,
           arguments[3] == "off" {
            return .init(command: .powerOffDisplay, selector: arguments[2])
        }
        return connectionRequest(arguments)
    }
    private static func connectionRequest(_ arguments: [String]) -> CrispControlRequest? {
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
