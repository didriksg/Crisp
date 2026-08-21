import Foundation
import CoreGraphics

/// Keeps DDC operations serial per physical display without coupling displays.
final class DDCOperationQueuePool: @unchecked Sendable {
    private let lock = NSLock()
    // ponytail: keep this small map for the process lifetime so a reused display ID
    // cannot overlap an in-flight operation on a second queue.
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
}
