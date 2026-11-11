import Foundation
import CoreGraphics
import os.log

/// Input select over DDC (#196). Switching away writes the new input and then
/// disconnects the display, because macOS keeps a monitor that shows another source
/// live and blank (the pointer and windows go onto it); Reconnect switches it back.
/// Measured on the desk: docs/ddc-notes.md (input switching).
@MainActor
final class InputSwitchService: ObservableObject {
    static let shared = InputSwitchService()

    private static let log = Logger(subsystem: "com.crisp.app", category: "ddc")

    /// Inputs each monitor's capabilities string lists, by display uuid; empty when the
    /// string has no input entry. Read once per monitor: it takes 10 to 30 s on some.
    @Published private(set) var listed: [String: [UInt16]]
    /// Displays whose capabilities string is being read now.
    @Published private(set) var reading: Set<String> = []
    private var readTasks: [String: Task<Void, Never>] = [:]
    /// The input this Mac is on, by display uuid: from the last validated read, or
    /// marked by the user on a monitor whose reads fail.
    @Published private(set) var macInput: [String: UInt16]
    /// Displays whose macInput the user marked, so the list offers to mark it again.
    @Published private(set) var markedByUser: Set<String>

    private let listedKey = "crisp.InputSourcesListed"
    private let macInputKey = "crisp.InputMacSource"
    private let markedKey = "crisp.InputMarkedByUser"

    private init() {
        let defaults = UserDefaults.standard
        listed = Self.load(defaults.dictionary(forKey: listedKey))
        macInput = (defaults.dictionary(forKey: macInputKey) as? [String: Int] ?? [:]).compactMapValues(UInt16.init(exactly:))
        markedByUser = Set(defaults.stringArray(forKey: markedKey) ?? [])
    }

    // MARK: - Queries

    /// The inputs to offer: what the monitor lists, else the standard list. A monitor
    /// with codes of its own is reached by number through crispctl and Shortcuts.
    func options(for display: DisplayInfo) -> [UInt16] {
        listed[display.displayUUID].flatMap { $0.isEmpty ? nil : $0 } ?? DDCInputSource.standard
    }

    /// Whether the display gets an Input row: an external whose DDC answers.
    /// Gated on write capability, not the brightness route: a display forced
    /// onto software brightness (acks-but-ignores brightness writes) can
    /// still take input-switch writes just fine.
    func isAvailable(for display: DisplayInfo) -> Bool {
        guard !display.isBuiltin, !display.hasNativeBrightness else { return false }
        let uuid = display.displayUUID
        return macInput[uuid] != nil || listed[uuid]?.isEmpty == false
            || BrightnessService.shared.isDDCAvailable(for: display.displayID) == true
    }

    // MARK: - Reads

    /// Reads the current input. A read that succeeds replaces a mark.
    func refreshInput(_ display: DisplayInfo) async {
        guard !display.isBuiltin, !display.hasNativeBrightness else { return }
        if let current = await DDCService.shared.readInput(displayID: display.displayID) {
            setMacInput(current, for: display.displayUUID, marked: false)
        }
    }

    /// Reads the capabilities string, once per monitor; started when the list is first
    /// opened, so a monitor nobody switches never sees the traffic. A second caller
    /// waits for the read already running.
    func readListIfNeeded(_ display: DisplayInfo) async {
        let uuid = display.displayUUID
        let displayID = display.displayID
        guard listed[uuid] == nil else { return }
        if let task = readTasks[uuid] { return await task.value }
        let task = Task {
            reading.insert(uuid)
            defer { reading.remove(uuid); readTasks[uuid] = nil }
            // A failed read is not stored, so the next opening tries again.
            guard let capabilities = await DDCService.shared.readCapabilities(displayID: displayID) else { return }
            let values = DDCInputSource.values(inCapabilities: capabilities) ?? []
            Self.log.notice("display \(displayID, privacy: .public) lists inputs \(values.map { String(format: "0x%02X", $0) }.joined(separator: " "), privacy: .public)")
            listed[uuid] = values
            save(listed, forKey: listedKey)
        }
        readTasks[uuid] = task
        await task.value
    }

    /// The final list and current input, for a caller that answers once (crispctl).
    func settle(_ display: DisplayInfo) async {
        await readListIfNeeded(display)
        await refreshInput(display)
    }

    // MARK: - User changes

    func mark(_ value: UInt16, for display: DisplayInfo) {
        setMacInput(value, for: display.displayUUID, marked: true)
    }

    func forgetMark(for display: DisplayInfo) {
        let uuid = display.displayUUID
        macInput[uuid] = nil
        markedByUser.remove(uuid)
        saveMacInput()
    }

    enum SwitchError: Error, CustomStringConvertible {
        case macInputUnknown
        case writeFailed

        var description: String {
            switch self {
            case .macInputUnknown: String(localized: "Crisp could not read which input this Mac is on. Choose it once in the menu.")
            case .writeFailed: String(localized: "The monitor did not take the input change.")
            }
        }
    }

    /// Switches the monitor to `value`, then disconnects it so macOS frees its space.
    /// Returns whether it was disconnected: not on Intel, and not when it is the last
    /// display, where it switches anyway (decided 2026-10-05: the user is going to the
    /// other computer, and the pointer has no other screen to go to).
    func switchInput(_ display: DisplayInfo, to value: UInt16) async -> Result<Bool, SwitchError> {
        let uuid = display.displayUUID
        let displayID = display.displayID
        if let current = await DDCService.shared.readInput(displayID: displayID) {
            setMacInput(current, for: uuid, marked: false)
        }
        guard let returnInput = macInput[uuid] else { return .failure(.macInputUnknown) }
        guard value != returnInput else { return .success(false) }
        guard await DDCService.shared.writeInput(displayID: displayID, value: value) else {
            return .failure(.writeFailed)
        }
        let toggle = PhysicalDisplayToggleService.shared
        guard toggle.isSupported, !toggle.wouldLeaveNoActiveDisplay(displayID) else {
            Self.log.notice("display \(displayID, privacy: .public) switched to input \(value, privacy: .public), kept connected")
            return .success(false)
        }
        let result = await toggle.disconnect(display, returnInput: returnInput)
        Self.log.notice("display \(displayID, privacy: .public) switched to input \(value, privacy: .public), disconnect: \(String(describing: result), privacy: .public)")
        if case .success = result { return .success(true) }
        return .success(false)
    }

    /// Reconnect for the user's own Reconnect (row, crispctl, Shortcuts), which also
    /// switches a monitor that left through an input switch back to this Mac. The
    /// blackout rescue calls PhysicalDisplayToggleService.reconnect directly, so it
    /// never takes a monitor away from the other computer.
    @discardableResult
    func reconnect(uuid: String) async -> Result<Void, PhysicalDisplayToggleService.ToggleError> {
        let toggle = PhysicalDisplayToggleService.shared
        let returnInput = toggle.disconnected.first { $0.uuid == uuid }?.returnInput
        let result = await toggle.reconnect(uuid: uuid)
        guard case .success = result, let returnInput else { return result }
        // One write: the monitor re-links to this Mac (a 1.5 s hot plug drop) when it lands.
        guard let displayID = Self.onlineDisplayID(uuid: uuid) else { return result }
        let written = await DDCService.shared.writeInputAfterReconnect(displayID: displayID, value: returnInput)
        Self.log.notice("display \(uuid, privacy: .public) reconnected, input \(returnInput, privacy: .public) written: \(written, privacy: .public)")
        return result
    }

    // MARK: - Private

    private static func onlineDisplayID(uuid: String) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).first { DisplayInfo.cgDisplayUUID($0) == uuid }
    }

    private func setMacInput(_ value: UInt16, for uuid: String, marked: Bool) {
        guard macInput[uuid] != value || markedByUser.contains(uuid) != marked else { return }
        macInput[uuid] = value
        if marked { markedByUser.insert(uuid) } else { markedByUser.remove(uuid) }
        saveMacInput()
    }

    private func saveMacInput() {
        UserDefaults.standard.set(macInput.mapValues(Int.init), forKey: macInputKey)
        UserDefaults.standard.set(Array(markedByUser), forKey: markedKey)
    }

    private func save(_ values: [String: [UInt16]], forKey key: String) {
        UserDefaults.standard.set(values.mapValues { $0.map(Int.init) }, forKey: key)
    }

    private static func load(_ stored: [String: Any]?) -> [String: [UInt16]] {
        (stored as? [String: [Int]] ?? [:]).mapValues { $0.compactMap(UInt16.init(exactly:)) }
    }
}
