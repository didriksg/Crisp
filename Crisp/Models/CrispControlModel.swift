import Foundation

enum CrispControlSocket {
    static let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("crispctl.sock").path
}
struct CrispControlDisplay: Codable, Equatable {
    let id: UInt32
    let name: String
    let brightness: Double
    let isBuiltin: Bool
    /// Stable identity across CGDirectDisplayID reassignment. A disconnected display
    /// keeps its uuid but its `id` is only the last-known runtime id.
    let uuid: String
    /// False while Crisp holds the display disconnected. Such a display is absent from
    /// CGGetOnlineDisplayList, so `uuid` is the only selector that survives.
    let connected: Bool

    init(
        id: UInt32,
        name: String,
        brightness: Double,
        isBuiltin: Bool,
        uuid: String = "",
        connected: Bool = true
    ) {
        self.id = id
        self.name = name
        self.brightness = brightness
        self.isBuiltin = isBuiltin
        self.uuid = uuid
        self.connected = connected
    }

    /// Hand-written so a crispctl built before these fields existed still decodes a
    /// reply from a newer Crisp, matching the forward-compatibility the help promises.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt32.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        brightness = try container.decode(Double.self, forKey: .brightness)
        isBuiltin = try container.decode(Bool.self, forKey: .isBuiltin)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid) ?? ""
        connected = try container.decodeIfPresent(Bool.self, forKey: .connected) ?? true
    }
}
struct CrispControlRequest: Codable, Equatable {
    enum Command: String, Codable {
        case list
        case getBrightness
        case setBrightness
        case connectDisplay
        case disconnectDisplay
        case toggleDisplay
    }

    let command: Command
    let display: UInt32?
    let brightness: Double?
    /// Display selector for the connection commands: a runtime id or a uuid, as typed.
    /// A disconnected display is gone from the online list, so its id alone cannot
    /// always find it; resolution against both is done in `handle`.
    let selector: String?
    init(
        command: Command,
        display: UInt32? = nil,
        brightness: Double? = nil,
        selector: String? = nil
    ) {
        self.command = command
        self.display = display
        self.brightness = brightness
        self.selector = selector
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
    let error: String?

    init(
        ok: Bool,
        displays: [CrispControlDisplay]? = nil,
        display: CrispControlDisplay? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.displays = displays
        self.display = display
        self.error = error
    }
    static func success() -> Self { Self(ok: true) }
    static func success(displays: [CrispControlDisplay]) -> Self { Self(ok: true, displays: displays) }
    static func success(display: CrispControlDisplay) -> Self { Self(ok: true, display: display) }
    static func failure(_ error: String) -> Self { Self(ok: false, error: error) }
}
struct CrispControlBrightnessChange: Equatable {
    let displayID: UInt32
    let brightness: Double
}
/// A resolved connect-or-disconnect. `toggleDisplay` is collapsed into a concrete
/// direction by `handle`, so the server never has to re-read the current state.
struct CrispControlConnectionChange: Equatable {
    let uuid: String
    let connect: Bool
}
enum CrispControlModel {
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
    /// Finds a display by the selector a person typed: a runtime id, or a uuid in any
    /// case. Ids are checked first because they are what `displays list` leads with.
    static func resolve(
        selector: String,
        in displays: [CrispControlDisplay]
    ) -> CrispControlDisplay? {
        if let id = UInt32(selector), let match = displays.first(where: { $0.id == id }) {
            return match
        }
        return displays.first { !$0.uuid.isEmpty && $0.uuid.caseInsensitiveCompare(selector) == .orderedSame }
    }

    static func handle(
        _ data: Data,
        displays: [CrispControlDisplay]
    ) -> (
        response: CrispControlResponse,
        brightnessChange: CrispControlBrightnessChange?,
        connectionChange: CrispControlConnectionChange?
    ) {
        guard let request = try? JSONDecoder().decode(CrispControlRequest.self, from: data) else {
            return (.failure("invalid request"), nil, nil)
        }
        switch request.command {
        case .list:
            return (.success(displays: displays), nil, nil)
        case .getBrightness:
            guard let id = request.display else { return (.failure("display is required"), nil, nil) }
            guard let display = displays.first(where: { $0.id == id }) else {
                return (.failure("display not found"), nil, nil)
            }
            return (.success(display: display), nil, nil)
        case .setBrightness:
            guard let id = request.display, let value = request.brightness else {
                return (.failure("display and brightness are required"), nil, nil)
            }
            guard (0...100).contains(value) else {
                return (.failure("brightness must be between 0 and 100"), nil, nil)
            }
            guard displays.contains(where: { $0.id == id }) else {
                return (.failure("display not found"), nil, nil)
            }
            return (.success(), .init(displayID: id, brightness: value), nil)
        case .connectDisplay, .disconnectDisplay, .toggleDisplay:
            return connection(request, displays: displays)
        }
    }

    /// Resolves a connection request against the merged online + disconnected list.
    /// Asking for the state a display is already in succeeds and changes nothing, so
    /// a button wired to `connect` or `disconnect` is safe to press twice.
    private static func connection(
        _ request: CrispControlRequest,
        displays: [CrispControlDisplay]
    ) -> (
        response: CrispControlResponse,
        brightnessChange: CrispControlBrightnessChange?,
        connectionChange: CrispControlConnectionChange?
    ) {
        guard let selector = request.selector, !selector.isEmpty else {
            return (.failure("display is required"), nil, nil)
        }
        guard let display = resolve(selector: selector, in: displays) else {
            return (.failure("display not found"), nil, nil)
        }
        guard !display.uuid.isEmpty else {
            return (.failure("display has no stable uuid, so it cannot be reconnected"), nil, nil)
        }
        let connect: Bool
        switch request.command {
        case .connectDisplay: connect = true
        case .disconnectDisplay: connect = false
        default: connect = !display.connected
        }
        let settled = CrispControlDisplay(
            id: display.id,
            name: display.name,
            brightness: display.brightness,
            isBuiltin: display.isBuiltin,
            uuid: display.uuid,
            connected: connect
        )
        guard display.connected != connect else { return (.success(display: settled), nil, nil) }
        return (.success(display: settled), nil, .init(uuid: display.uuid, connect: connect))
    }
}
enum CrispControlCLIModel {
    static let usage = "usage: crispctl displays list | crispctl brightness get <display-id> | "
        + "crispctl brightness set <display-id> <percent> | "
        + "crispctl display connect|disconnect|toggle <display> | crispctl help"

    /// The full reference, for a person at a terminal and for an agent that reads it
    /// before acting. Kept in the shared model so the app and the CLI cannot drift.
    static let help = """
        crispctl: control a running Crisp from the command line.

        Crisp must be running on this Mac under the same user. crispctl talks to it
        over a local Unix socket (mode 0600 in the per-user temp dir) and never
        launches the app. Source builds only for now; the DMG and the Homebrew cask
        do not ship crispctl.

        Commands
          crispctl displays list
              Every display: id, name, brightness (0-100), isBuiltin, uuid, and
              connected. Includes displays Crisp is holding disconnected, which
              report connected:false and are absent from every macOS display list.
          crispctl brightness get <display-id>
              Current brightness of one display.
          crispctl brightness set <display-id> <percent>
              Set brightness, 0-100. Same path as the panel slider: hardware (DDC)
              or software dimming as Crisp decided for that display, and it clears
              the active preset. The reply means Crisp accepted the request, not
              that the panel was read back; run brightness get to confirm.
          crispctl display disconnect <display>
              Drop the display out of the layout, the same as Disconnect Display in
              the menu. Windows move off it and macOS stops treating it as attached.
              Apple Silicon only. Refused if it would leave no active display.
          crispctl display connect <display>
              Put a disconnected display back.
          crispctl display toggle <display>
              Disconnect it if connected, reconnect it if not. One idempotent verb
              for a single button.
          crispctl help
              This text. Also --help and -h.

        Display ids
          Runtime ids from displays list. They can change after an unplug or a
          wake, so list first, then act.

        Selecting a display for connect / disconnect / toggle
          <display> is a runtime id or a uuid; ids are matched first. A disconnected
          display is absent from CGGetOnlineDisplayList, so its runtime id is only a
          last-known value: use the uuid for anything that must survive a replug or
          a wake. displays list reports both, and reports connected:false for a
          display Crisp is holding disconnected.

        Connection results
          Asking for the state a display is already in succeeds and changes nothing.
          Unlike brightness, these replies are not optimistic: an error means the
          window server refused, and the reply carries Crisp's reason.

        Output
          One JSON object per call. Success: {"ok":true,...}. Failure:
          {"ok":false,"error":"..."}. Later versions may add fields; ignore
          what you do not know. Crisp's own refusals come back on stdout,
          crispctl's own errors (no socket, bad arguments) go to stderr.

        Exit codes
          0  ok
          1  could not reach Crisp: not running, socket missing, another user,
             or an unreadable reply
          2  bad arguments
          3  Crisp refused the request: unknown display, value out of range
        """

    enum ParseResult: Equatable {
        case request(CrispControlRequest)
        case help
        case failure
    }
    enum ResponseResult: Equatable { case success, serverFailure, invalid }
    static func parse(arguments: [String]) -> ParseResult {
        if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            return .help
        }
        if arguments == ["displays", "list"] {
            return .request(.init(command: .list))
        }
        if arguments.count == 3, arguments[0...1] == ["brightness", "get"],
           let id = UInt32(arguments[2]) {
            return .request(.init(command: .getBrightness, display: id))
        }
        if arguments.count == 4, arguments[0...1] == ["brightness", "set"],
           let id = UInt32(arguments[2]), let value = Double(arguments[3]),
           value.isFinite, (0...100).contains(value) {
            return .request(.init(command: .setBrightness, display: id, brightness: value))
        }
        if arguments.count == 3, arguments[0] == "display", !arguments[2].isEmpty {
            let command: CrispControlRequest.Command?
            switch arguments[1] {
            case "connect": command = .connectDisplay
            case "disconnect": command = .disconnectDisplay
            case "toggle": command = .toggleDisplay
            default: command = nil
            }
            if let command {
                return .request(.init(command: command, selector: arguments[2]))
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
