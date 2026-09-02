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
        let result = CrispControlModel.handle(request, displays: knownDisplays())
        if let change = result.brightnessChange {
            guard let display = displayManager.displays.first(where: { $0.displayID == change.displayID }) else {
                return CrispControlModel.encode(.failure("display not found"))
            }
            await BrightnessService.shared.setBrightness(change.brightness, for: display)
        }
        if let change = result.connectionChange, let error = await apply(change) {
            return CrispControlModel.encode(.failure(error))
        }
        return CrispControlModel.encode(result.response)
    }

    /// Online displays plus the ones Crisp is holding disconnected. A disconnected
    /// display is gone from DisplayManager (CGGetOnlineDisplayList omits it), so
    /// without the second half `connect` could never name its target.
    private func knownDisplays() -> [CrispControlDisplay] {
        let online = displayManager.displays.map {
            CrispControlDisplay(
                id: $0.displayID, name: $0.name,
                brightness: min($0.brightness, 100), isBuiltin: $0.isBuiltin,
                uuid: $0.displayUUID, connected: true
            )
        }
        let live = Set(online.map(\.uuid))
        let offline = PhysicalDisplayToggleService.shared.disconnected
            .filter { !live.contains($0.uuid) }
            .map {
                CrispControlDisplay(
                    id: $0.displayID, name: $0.name,
                    brightness: 0, isBuiltin: false,
                    uuid: $0.uuid, connected: false
                )
            }
        return online + offline
    }

    /// Applies a resolved connection change. Returns nil on success, or the reason
    /// the window server refused. Unlike brightness this is not fire-and-forget:
    /// disconnecting can be legitimately refused (it would leave no active display),
    /// and a caller wiring this to a button needs to hear that.
    private func apply(_ change: CrispControlConnectionChange) async -> String? {
        let service = PhysicalDisplayToggleService.shared
        if change.connect {
            if case let .failure(error) = await service.reconnect(uuid: change.uuid) {
                return error.description
            }
            return nil
        }
        guard let display = displayManager.displays.first(where: { $0.displayUUID == change.uuid }) else {
            return "display not found"
        }
        if case let .failure(error) = await service.disconnect(display) {
            return error.description
        }
        return nil
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
