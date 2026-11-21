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
    /// Displays whose mark the user cleared with Choose Again and has not set again: the
    /// Input row stays while they choose, even where the cleared value was its only reason.
    @Published private(set) var choosing: Set<String> = []

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

    /// The inputs to offer: what the monitor lists, else the standard list, and on an LG
    /// display also LG's side-channel codes, which many LG monitors need because they
    /// ignore VCP 0x60 writes. Once this Mac's input is marked as an LG code, only the
    /// LG codes: a 0x60 write would be ignored and leave the display disconnected.
    /// A monitor with other codes of its own is reached by number through crispctl and
    /// Shortcuts.
    func options(for display: DisplayInfo) -> [UInt16] {
        if hasLGMark(display.displayUUID) { return DDCInputSource.lg }
        let base = listed[display.displayUUID].flatMap { $0.isEmpty ? nil : $0 } ?? DDCInputSource.standard
        return offersLGInputs(display) ? base + DDCInputSource.lg : base
    }

    /// Whether the display is an LG monitor, which gets LG's side-channel inputs.
    func offersLGInputs(_ display: DisplayInfo) -> Bool {
        display.vendorNumber == DDCInputSource.lgVendor
    }

    /// Whether the input list offers Choose Again: after a mark, and on an LG monitor
    /// whose input is not an LG mark, because a 0x60 read there is often wrong and a
    /// switch through LG's side channel needs this Mac's input marked as an LG code.
    func offersChoosingAgain(_ display: DisplayInfo) -> Bool {
        guard let current = macInput[display.displayUUID] else { return false }
        return markedByUser.contains(display.displayUUID) || (offersLGInputs(display) && !DDCInputSource.isLG(current))
    }

    /// Whether the user marked this Mac's input as an LG side-channel code. A VCP 0x60
    /// read does not describe that channel (and on LG monitors over HDMI it is often
    /// wrong), so such a mark is never replaced by a read.
    private func hasLGMark(_ uuid: String) -> Bool {
        markedByUser.contains(uuid) && macInput[uuid].map(DDCInputSource.isLG) == true
    }

    /// Whether the display gets an Input row: an external whose DDC answers.
    /// Gated on write capability, not the brightness route: a display forced
    /// onto software brightness (acks-but-ignores brightness writes) can
    /// still take input-switch writes just fine.
    func isAvailable(for display: DisplayInfo) -> Bool {
        guard !display.isBuiltin, !display.hasNativeBrightness else { return false }
        let uuid = display.displayUUID
        return macInput[uuid] != nil || listed[uuid]?.isEmpty == false || choosing.contains(uuid)
            || BrightnessService.shared.isDDCAvailable(for: display.displayID) == true
    }

    // MARK: - Reads

    /// Reads the current input. A read that succeeds replaces a mark, except an LG
    /// side-channel mark (hasLGMark).
    func refreshInput(_ display: DisplayInfo) async {
        guard !display.isBuiltin, !display.hasNativeBrightness, !hasLGMark(display.displayUUID) else { return }
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
        choosing.insert(uuid)
        saveMacInput()
    }

    enum SwitchError: Error, CustomStringConvertible {
        case macInputUnknown
        case writeFailed
        case lgChannelOnly
        case lgMacInputUnmarked

        var description: String {
            switch self {
            case .macInputUnknown: String(localized: "Crisp could not read which input this Mac is on. Choose it once in the menu.")
            case .writeFailed: String(localized: "The monitor did not take the input change.")
            case .lgChannelOnly: String(localized: "This monitor switches through LG's channel. Choose an input marked (LG).")
            case .lgMacInputUnmarked: String(localized: "Click Choose Again, then choose the (LG) input this Mac is on.")
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
        if !hasLGMark(uuid), let current = await DDCService.shared.readInput(displayID: displayID) {
            setMacInput(current, for: uuid, marked: false)
        }
        guard let returnInput = macInput[uuid] else { return .failure(.macInputUnknown) }
        if value == returnInput {
            // A 0x60 read tells which input a standard monitor shows; nothing tells it for an
            // LG code, so a display that stayed connected while it showed the other computer
            // (Intel, or the last display) has no other way back than an explicit request,
            // which writes it. Requesting the input already shown makes the monitor re-link
            // once (docs/ddc-notes.md); the pickers never send it, since this Mac's input is
            // their checked item, so only crispctl and Shortcuts can.
            guard DDCInputSource.isLG(value) else { return .success(false) }
            let written = await DDCService.shared.writeInput(displayID: displayID, value: value)
            return written ? .success(false) : .failure(.writeFailed)
        }
        // The way out and the way back use one channel. A monitor that leaves through LG's
        // side channel ignores a VCP 0x60 write on Reconnect, so it needs this Mac's input
        // marked as an LG code; and with that mark, a 0x60 write would be ignored too and
        // only disconnect the display.
        if DDCInputSource.isLG(value), !DDCInputSource.isLG(returnInput) { return .failure(.lgMacInputUnmarked) }
        if !DDCInputSource.isLG(value), DDCInputSource.isLG(returnInput) { return .failure(.lgChannelOnly) }
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
        // Checked here, after the read's await, so a read that started before the user
        // marked an LG code cannot replace that mark when it lands.
        guard marked || !hasLGMark(uuid) else { return }
        // While the user chooses again, a read (one already in flight, or one from opening
        // the panel) must not fill the value back in: the next click would switch, not mark.
        guard marked || !choosing.contains(uuid) else { return }
        if marked { choosing.remove(uuid) }
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
