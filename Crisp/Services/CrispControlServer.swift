import Darwin
import Foundation
import os

@MainActor
final class CrispControlServer {
    private nonisolated static let requestLimit = 8 * 1_024
    /// Same-user clients only, so these bound a runaway script rather than an
    /// attacker: a connection holds a cooperative-pool thread until it is answered,
    /// and the per-recv timeout alone lets a client trickle bytes for ever.
    private nonisolated static let readDeadline: DispatchTimeInterval = .seconds(5)
    private nonisolated static let connectionLimit = 16
    private nonisolated static let openConnections = OSAllocatedUnfairLock(initialState: 0)
    private let displayManager: DisplayManager
    private let acceptQueue = DispatchQueue(label: "com.crisp.app.control", qos: .utility)
    private var listenerFD: Int32 = -1

    init(displayManager: DisplayManager) { self.displayManager = displayManager }

    /// The server AppDelegate started, for the Shortcuts actions: they send the same
    /// requests in-process, so they share crispctl's checks, errors and serialisation.
    private(set) static weak var running: CrispControlServer?

    /// One request without the socket, answered by the same path crispctl's are.
    func handle(_ request: CrispControlRequest) async -> CrispControlResponse {
        guard let data = try? JSONEncoder().encode(request) else { return .failure("invalid request") }
        let reply = await response(to: data)
        return (try? JSONDecoder().decode(CrispControlResponse.self, from: reply)) ?? .failure("response decoding failed")
    }

    func start() throws {
        Self.running = self
        guard listenerFD == -1 else { return }
        let path = CrispControlSocket.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw ServerError("control socket path is too long")
        }
        try Self.removeOwnedSocket(path)
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Self.failure("socket") }
        do {
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                path.withCString { bytes.baseAddress?.copyMemory(from: $0, byteCount: path.utf8.count + 1) }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw Self.failure("bind") }
            guard Darwin.chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw Self.failure("chmod") }
            guard Darwin.listen(listener, 8) == 0 else { throw Self.failure("listen") }
        } catch {
            Darwin.close(listener)
            try? Self.removeOwnedSocket(path)
            throw error
        }
        listenerFD = listener
        acceptQueue.async { [weak self] in self?.acceptConnections(listener) }
    }

    func stop() {
        guard listenerFD >= 0 else { return }
        Darwin.shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        listenerFD = -1
        try? Self.removeOwnedSocket(CrispControlSocket.path)
    }

    private nonisolated func acceptConnections(_ listener: Int32) {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            guard Self.configure(client), Self.isCurrentUser(client), Self.admit() else {
                Darwin.close(client)
                continue
            }
            Task.detached { [weak self] in
                defer {
                    Darwin.close(client)
                    Self.openConnections.withLock { $0 -= 1 }
                }
                await self?.serve(client)
            }
        }
    }

    private nonisolated func serve(_ client: Int32) async {
        let data: Data
        switch Self.read(client) {
        case let .frame(request): data = await response(to: request)
        case let .failure(message): data = CrispControlModel.encode(.failure(message))
        case .incomplete: data = CrispControlModel.encode(.failure("request read failed"))
        }
        Self.write(data, to: client)
    }

    /// Connection changes run one at a time: two disconnects fired together for the last
    /// two displays both passed disconnect()'s last-screen guard and blacked out every
    /// screen. Brightness and HDR stay concurrent, since a reconnect can hold the line
    /// for seconds.
    private var connectionChain: Task<Void, Never>?

    private func response(to request: Data) async -> Data {
        guard Self.changesConnection(request) else { return await reply(to: request) }
        let previous = connectionChain
        let task = Task { @MainActor in
            await previous?.value
            return await self.reply(to: request)
        }
        connectionChain = Task { _ = await task.value }
        return await task.value
    }

    private nonisolated static func changesConnection(_ request: Data) -> Bool {
        switch (try? JSONDecoder().decode(CrispControlRequest.self, from: request))?.command {
        case .connectDisplay, .disconnectDisplay, .toggleDisplay, .setInput: return true
        default: return false
        }
    }

    private func reply(to request: Data) async -> Data {
        let managedDisplays = displayManager.displays
        let boostService = BrightnessBoostService.shared
        let displays = managedDisplays.map { display in
            let resolution = display.currentDisplayMode.map { mode in
                CrispControlResolution(
                    logicalWidth: mode.width,
                    logicalHeight: mode.height,
                    pixelWidth: mode.pixelWidth,
                    pixelHeight: mode.pixelHeight,
                    refreshRate: mode.refreshRate,
                    isHiDPI: mode.isHiDPI
                )
            }
            return CrispControlDisplay(
                id: display.displayID,
                name: display.name,
                brightness: display.brightness,
                maxBrightness: boostService.maximumBrightness(for: display),
                isBuiltin: display.isBuiltin,
                uuid: display.displayUUID,
                resolution: resolution,
                brightnessBackend: BrightnessService.shared.brightnessBackend(for: display),
                connected: true
            )
        }
        // Plus the displays Crisp is holding disconnected. They are gone from
        // DisplayManager (CGGetOnlineDisplayList omits them), and without this half
        // `connect` could never name its target.
        let held = PhysicalDisplayToggleService.shared.disconnected
            .filter { record in !managedDisplays.contains { $0.displayUUID == record.uuid } }
            .map { record in
                CrispControlDisplay(
                    id: record.displayID, name: record.name, brightness: 0,
                    isBuiltin: record.isBuiltin ?? false, uuid: record.uuid, connected: false
                )
            }
        let result = CrispControlModel.handle(
            request,
            displays: displays + held,
            hdrState: { id in
                guard let display = managedDisplays.first(where: { $0.displayID == id }),
                      let enabled = boostService.hdrState(for: display, expectedUUID: display.displayUUID)
                else { return nil }
                return CrispControlHDRState(
                    displayID: id,
                    enabled: enabled
                )
            },
            hdrMutationUUID: { id in
                managedDisplays.first(where: { $0.displayID == id })
                    .flatMap { boostService.uniqueDisplayUUID(for: $0) }
            },
            brightnessBoostState: { id in
                guard let display = managedDisplays.first(where: { $0.displayID == id }) else { return nil }
                return CrispControlBrightnessBoostState(
                    displayID: id,
                    eligible: boostService.isEligible(display),
                    enabled: boostService.isEnabled(for: display)
                )
            },
            presets: PresetService.shared.presets.map(Self.listed),
            imageAdjustment: { id in
                managedDisplays.first(where: { $0.displayID == id }).map { display in
                    (GammaService.shared.loadSavedState(for: display) ?? GammaAdjustment())
                        .controlValues(displayID: id, uuid: display.displayUUID, name: display.name)
                }
            }
        )
        if let change = result.brightnessChange {
            guard let display = managedDisplays.first(where: { $0.displayID == change.displayID }) else {
                return CrispControlModel.encode(.failure("display not found"))
            }
            if change.brightness > 100,
               let maximum = displays.first(where: { $0.id == change.displayID })?.maxBrightness {
                boostService.settleMaximumBrightness(maximum, for: display)
            }
            await BrightnessService.shared.setBrightness(change.brightness, for: display)
        }
        if let change = result.brightnessBoostChange {
            guard let display = managedDisplays.first(where: { $0.displayID == change.displayID }) else {
                return CrispControlModel.encode(.failure("display not found"))
            }
            guard !change.enabled || boostService.isEligible(display) else {
                return CrispControlModel.encode(.failure("extra brightness is not eligible for this display"))
            }
            let accepted = await boostService.setEnabled(change.enabled, for: display)
            return CrispControlModel.encode(
                CrispControlModel.brightnessBoostSetResponse(enabled: change.enabled, accepted: accepted)
            )
        }
        if let change = result.hdrChange {
            return await hdrResponse(for: change, using: boostService)
        }
        if let change = result.connectionChange, let error = await apply(change, among: managedDisplays) {
            return CrispControlModel.encode(.failure(error))
        }
        if let id = result.presetToApply {
            return await applyPreset(id: id)
        }
        if let change = result.imageChange {
            guard let display = managedDisplays.first(where: { $0.displayID == change.displayID }) else {
                return CrispControlModel.encode(.failure("display not found"))
            }
            // A set changes one value and keeps the rest, pause included, like a slider;
            // a reset is Reset All.
            let saved = GammaService.shared.loadSavedState(for: display) ?? GammaAdjustment()
            let adjustment = change.setting.map { saved.setting($0, to: change.value) } ?? GammaAdjustment()
            GammaService.shared.set(adjustment, for: display)
            return CrispControlModel.encode(.success(image: adjustment.controlValues(
                displayID: display.displayID, uuid: display.displayUUID, name: display.name
            )))
        }
        if let id = result.inputListDisplayID {
            return await inputList(displayID: id, among: managedDisplays)
        }
        if let change = result.inputChange {
            return await switchInput(change, among: managedDisplays, listed: displays)
        }
        return CrispControlModel.encode(result.response)
    }

    private func inputList(displayID: UInt32, among managedDisplays: [DisplayInfo]) async -> Data {
        let service = InputSwitchService.shared
        guard let display = managedDisplays.first(where: { $0.displayID == displayID }) else {
            return CrispControlModel.encode(.failure("display not found"))
        }
        guard service.isAvailable(for: display) else { return CrispControlModel.encode(.failure(Self.noDDC)) }
        await service.settle(display)
        let inputs = service.options(for: display).map { value in
            CrispControlInput(value: Int(value), name: DDCInputSource.name(for: value) ?? String(format: "Input 0x%02X", value))
        }
        return CrispControlModel.encode(.success(inputs: CrispControlInputs(
            displayID: displayID, uuid: display.displayUUID,
            current: service.macInput[display.displayUUID].map(Int.init), inputs: inputs
        )))
    }

    private func switchInput(
        _ change: CrispControlInputChange, among managedDisplays: [DisplayInfo], listed: [CrispControlDisplay]
    ) async -> Data {
        let service = InputSwitchService.shared
        guard let display = managedDisplays.first(where: { $0.displayID == change.displayID }),
              let entry = listed.first(where: { $0.id == change.displayID }) else {
            return CrispControlModel.encode(.failure("display not found"))
        }
        guard service.isAvailable(for: display) else { return CrispControlModel.encode(.failure(Self.noDDC)) }
        guard let value = DDCInputSource.value(from: change.input) else {
            return CrispControlModel.encode(.failure(
                "unknown input '\(change.input)'; use a name such as hdmi1 or a number such as 17 or 0x11"
            ))
        }
        let result = await service.switchInput(display, to: value)
        displayManager.refreshDisplays()
        switch result {
        case .failure(let error):
            return CrispControlModel.encode(.failure(error.description))
        case .success(let disconnected):
            return CrispControlModel.encode(.success(display: CrispControlDisplay(
                id: entry.id, name: entry.name, brightness: entry.brightness, maxBrightness: entry.maxBrightness,
                isBuiltin: entry.isBuiltin, uuid: entry.uuid, resolution: entry.resolution,
                brightnessBackend: entry.brightnessBackend, connected: !disconnected
            )))
        }
    }

    private static let noDDC = "this display does not answer DDC, so Crisp cannot read or switch its input"

    private static func listed(_ preset: DisplayPreset) -> CrispControlPreset {
        CrispControlPreset(
            id: preset.id.uuidString,
            name: preset.name,
            captures: PresetCapture.allCases.filter(preset.includes).map(\.rawValue),
            displays: preset.displays.map(\.displayUUID),
            active: PresetService.shared.activePresetID == preset.id
        )
    }

    private func applyPreset(id: String) async -> Data {
        let service = PresetService.shared
        guard let preset = service.presets.first(where: { $0.id.uuidString == id }) else {
            return CrispControlModel.encode(.failure("preset not found"))
        }
        // applyPreset returns at once, having done nothing, while another apply runs.
        guard !service.isApplying else {
            return CrispControlModel.encode(.failure("another preset is being applied; try again"))
        }
        await service.applyPreset(preset)
        // applyPreset skips a display that is not online without a word; say which. Read after
        // the apply, which can turn displays on and off (#211); one the preset turns off is not skipped.
        let online = displayManager.displays.filter(\.isOnline).map(\.displayUUID)
        let skipped = preset.displays
            .filter { $0.connected != false && !online.contains($0.displayUUID) }
            .map(\.displayUUID)
        return CrispControlModel.encode(.success(preset: Self.listed(preset), skippedDisplays: skipped))
    }

    private func hdrResponse(
        for change: CrispControlHDRChange, using boostService: BrightnessBoostService
    ) async -> Data {
        guard let display = currentHDRTarget(for: change, using: boostService) else {
            return CrispControlModel.encode(
                CrispControlModel.hdrSetResponse(
                    displayID: change.displayID,
                    enabled: change.enabled,
                    accepted: false,
                    liveEnabled: nil
                )
            )
        }
        let accepted = await boostService.setHDRPreference(
            change.enabled, for: display, expectedUUID: change.displayUUID
        )
        var liveEnabled = currentHDRTarget(for: change, using: boostService).flatMap {
            boostService.hdrState(for: $0, expectedUUID: change.displayUUID)
        }
        if accepted {
            for _ in 0..<20 {
                guard liveEnabled != change.enabled else { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let current = currentHDRTarget(for: change, using: boostService) else {
                    liveEnabled = nil
                    break
                }
                liveEnabled = boostService.hdrState(
                    for: current, expectedUUID: change.displayUUID
                )
            }
        }
        if liveEnabled == change.enabled {
            liveEnabled = currentHDRTarget(for: change, using: boostService).flatMap {
                boostService.hdrState(for: $0, expectedUUID: change.displayUUID)
            }
        }
        return CrispControlModel.encode(
            CrispControlModel.hdrSetResponse(
                displayID: change.displayID,
                enabled: change.enabled,
                accepted: accepted,
                liveEnabled: liveEnabled
            )
        )
    }

    /// Applies a connection change, returning nil or the refusal reason. Not fire-and-forget
    /// like brightness: a disconnect can be legitimately refused (last active display), and
    /// the caller needs to hear why.
    private func apply(_ change: CrispControlConnectionChange, among managedDisplays: [DisplayInfo]) async -> String? {
        let service = PhysicalDisplayToggleService.shared
        let outcome: Result<Void, PhysicalDisplayToggleService.ToggleError>
        if change.connect {
            outcome = await InputSwitchService.shared.reconnect(uuid: change.uuid)
        } else if let display = managedDisplays.first(where: { $0.displayUUID == change.uuid }) {
            outcome = await service.disconnect(display)
        } else {
            return "display not found"
        }
        displayManager.refreshDisplays()
        if case let .failure(error) = outcome { return error.description }
        return nil
    }

    private func currentHDRTarget(
        for change: CrispControlHDRChange, using service: BrightnessBoostService
    ) -> DisplayInfo? {
        guard let display = displayManager.displays.first(where: { $0.displayID == change.displayID }),
              service.uniqueDisplayUUID(for: display)?.caseInsensitiveCompare(change.displayUUID)
                == .orderedSame else { return nil }
        return display
    }

    private nonisolated static func admit() -> Bool {
        openConnections.withLock { open in
            guard open < connectionLimit else { return false }
            open += 1
            return true
        }
    }

    private nonisolated static func read(_ client: Int32) -> CrispControlFrame.Result {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        let deadline = DispatchTime.now() + readDeadline
        while true {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            if count > 0 { data.append(contentsOf: buffer.prefix(Int(count))) }
            let result = CrispControlFrame.parse(data, maximumBytes: requestLimit, endOfStream: count == 0)
            if result != .incomplete { return result }
            if count < 0, errno != EINTR { return .failure("request read failed") }
            if DispatchTime.now() >= deadline { return .failure("request read timed out") }
        }
    }

    private nonisolated static func write(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.send(client, pointer, remaining, 0)
                if count > 0 {
                    pointer = pointer.advanced(by: count)
                    remaining -= count
                } else if count < 0, errno == EINTR { continue } else { return }
            }
        }
    }

    private nonisolated static func configure(_ client: Int32) -> Bool {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        var enabled: Int32 = 1
        return setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0
            && setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0
            && setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private nonisolated static func isCurrentUser(_ client: Int32) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        return getpeereid(client, &user, &group) == 0 && user == geteuid()
    }

    private nonisolated static func removeOwnedSocket(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw failure("lstat")
        }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
            throw ServerError("control socket path is occupied by another file")
        }
        guard Darwin.unlink(path) == 0 else { throw failure("unlink") }
    }

    private nonisolated static func failure(_ name: String) -> ServerError {
        ServerError("control socket \(name) failed: \(String(cString: strerror(errno)))")
    }

    private struct ServerError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
