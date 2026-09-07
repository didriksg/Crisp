import Darwin
import Foundation
private struct ClientFailure: Error { let message: String }
private func systemFailure(_ operation: String) -> ClientFailure {
    ClientFailure(message: "control socket \(operation) failed: \(String(cString: strerror(errno)))")
}
private func connectToCrisp(receiveTimeoutSeconds: Int) throws -> Int32 {
    let path = CrispControlSocket.path
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        throw ClientFailure(message: "control socket path is too long")
    }
    var info = stat()
    guard lstat(path, &info) == 0,
          info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
        throw ClientFailure(message: "Crisp control socket is unavailable or untrusted")
    }
    let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard client >= 0 else { throw systemFailure("creation") }
    do {
        var receiveTimeout = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        var enabled: Int32 = 1
        guard setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, timeoutSize) == 0,
              setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, timeoutSize) == 0,
              setsockopt(
                  client,
                  SOL_SOCKET,
                  SO_NOSIGPIPE,
                  &enabled,
                  socklen_t(MemoryLayout<Int32>.size)
              ) == 0 else { throw systemFailure("configuration") }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            path.withCString {
                bytes.baseAddress?.copyMemory(from: $0, byteCount: path.utf8.count + 1)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw systemFailure("connect") }
        var peerUser: uid_t = 0
        var peerGroup: gid_t = 0
        guard getpeereid(client, &peerUser, &peerGroup) == 0, peerUser == geteuid() else {
            throw ClientFailure(message: "control socket peer is untrusted")
        }
        return client
    } catch {
        Darwin.close(client)
        throw error
    }
}
private func send(_ data: Data, to client: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard var pointer = bytes.baseAddress else { return }
        var remaining = bytes.count
        while remaining > 0 {
            let count = Darwin.send(client, pointer, remaining, 0)
            if count > 0 {
                pointer = pointer.advanced(by: count)
                remaining -= count
            } else if count < 0, errno == EINTR {
                continue
            } else { throw systemFailure("write") }
        }
    }
}
private func receive(from client: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = Darwin.recv(client, &buffer, buffer.count, 0)
        if count > 0 { data.append(contentsOf: buffer.prefix(Int(count))) }
        let result = CrispControlFrame.parse(
            data,
            maximumBytes: 64 * 1_024,
            endOfStream: count == 0
        )
        switch result {
        case let .frame(frame): return frame
        case let .failure(message): throw ClientFailure(message: message)
        case .incomplete:
            if count < 0, errno != EINTR { throw systemFailure("read") }
        }
    }
}
private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(CrispControlModel.encode(.failure(message)))
    Darwin.exit(code)
}
let request: CrispControlRequest
switch CrispControlCLIModel.parse(arguments: Array(CommandLine.arguments.dropFirst())) {
case let .request(value): request = value
case .help:
    print(CrispControlCLIModel.help)
    Darwin.exit(EXIT_SUCCESS)
case .failure: fail(CrispControlCLIModel.usage, code: 2)
}
do {
    let client = try connectToCrisp(
        receiveTimeoutSeconds: CrispControlCLIModel.receiveTimeoutSeconds(for: request.command)
    )
    defer { Darwin.close(client) }
    try send(CrispControlModel.encode(request, sorted: true), to: client)
    let response: Data
    do {
        response = try receive(from: client)
    } catch {
        guard request.command != .setHDR else {
            fail("HDR response timed out or was lost; \(CrispControlModel.hdrUncertainRecovery)", code: 1)
        }
        throw error
    }
    switch CrispControlCLIModel.classify(response, for: request.command) {
    case .success:
        FileHandle.standardOutput.write(response)
        Darwin.exit(EXIT_SUCCESS)
    case .serverFailure:
        FileHandle.standardOutput.write(response)
        Darwin.exit(3)
    case .invalid:
        throw ClientFailure(message: "server returned invalid response")
    }
} catch let failure as ClientFailure {
    fail(failure.message, code: 1)
} catch {
    fail(error.localizedDescription, code: 1)
}
