import Darwin
import Foundation

@MainActor
final class CrispControlServer {
    private nonisolated static let requestLimit = 8 * 1_024
    private let displayManager: DisplayManager
    private let acceptQueue = DispatchQueue(label: "com.crisp.app.control", qos: .utility)
    private var listenerFD: Int32 = -1

    init(displayManager: DisplayManager) { self.displayManager = displayManager }

    func start() throws {
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
            guard Self.configure(client), Self.isCurrentUser(client) else {
                Darwin.close(client)
                continue
            }
            Task.detached { [weak self] in
                defer { Darwin.close(client) }
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

    private func response(to request: Data) async -> Data {
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
                uuid: boostService.stableDisplayUUID(for: display),
                resolution: resolution,
                brightnessBackend: BrightnessService.shared.brightnessBackend(for: display)
            )
        }
        let result = CrispControlModel.handle(
            request,
            displays: displays,
            hdrState: { id in
                guard let display = managedDisplays.first(where: { $0.displayID == id }),
                      let uuid = boostService.stableDisplayUUID(for: display),
                      let enabled = boostService.hdrState(for: display, expectedUUID: uuid) else { return nil }
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
        return CrispControlModel.encode(result.response)
    }

    private func currentHDRTarget(
        for change: CrispControlHDRChange, using service: BrightnessBoostService
    ) -> DisplayInfo? {
        guard let display = displayManager.displays.first(where: { $0.displayID == change.displayID }),
              service.uniqueDisplayUUID(for: display)?.caseInsensitiveCompare(change.displayUUID)
                == .orderedSame else { return nil }
        return display
    }

    private nonisolated static func read(_ client: Int32) -> CrispControlFrame.Result {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            if count > 0 { data.append(contentsOf: buffer.prefix(Int(count))) }
            let result = CrispControlFrame.parse(data, maximumBytes: requestLimit, endOfStream: count == 0)
            if result != .incomplete { return result }
            if count < 0, errno != EINTR { return .failure("request read failed") }
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
