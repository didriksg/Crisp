import Foundation
import CoreGraphics

/// Keeps DDC operations serial per physical display without coupling displays.
final class DDCOperationQueuePool: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [CGDirectDisplayID: DispatchQueue] = [:]

    func queue(for displayID: CGDirectDisplayID) -> DispatchQueue {
        lock.withLock {
            if let queue = queues[displayID] { return queue }
            let queue = DispatchQueue(
                label: "com.crisp.ddc.\(displayID)",
                qos: .userInitiated
            )
            queues[displayID] = queue
            return queue
        }
    }

    func removeQueue(for displayID: CGDirectDisplayID) {
        lock.withLock { _ = queues.removeValue(forKey: displayID) }
    }
}
