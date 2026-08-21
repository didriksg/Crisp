import Foundation
import CoreGraphics

/// Keeps DDC operations serial per physical display without coupling displays.
final class DDCOperationQueuePool: @unchecked Sendable {
    /// One outstanding `hold`. Kept as a reference so a release only ever signals
    /// the queues its own hold parked, even if another hold started meanwhile.
    private final class Hold {
        let gate = DispatchSemaphore(value: 0)
        let timeout: TimeInterval
        var parked = 0

        init(timeout: TimeInterval) { self.timeout = timeout }
    }

    private let lock = NSLock()
    private var queues: [CGDirectDisplayID: DispatchQueue] = [:]
    private var activeHolds: [Hold] = []

    func queue(for displayID: CGDirectDisplayID) -> DispatchQueue {
        lock.lock()
        if let queue = queues[displayID] {
            lock.unlock()
            return queue
        }
        let queue = DispatchQueue(
            label: "com.crisp.ddc.\(displayID)",
            qos: .userInitiated
        )
        queues[displayID] = queue
        // A display that gets its first operation during a hold is held too.
        let holds = activeHolds
        for hold in holds { hold.parked += 1 }
        lock.unlock()
        for hold in holds {
            queue.async { _ = hold.gate.wait(timeout: .now() + hold.timeout) }
        }
        return queue
    }

    func removeQueue(for displayID: CGDirectDisplayID) {
        lock.withLock { _ = queues.removeValue(forKey: displayID) }
    }

    /// Parks every per-display queue, present and future, until the returned closure
    /// runs. `onIdle` fires once every operation that was already queued has finished,
    /// so the caller can start its transaction knowing the I2C engine is free. Each
    /// parked queue gives up after `timeout` so a lost release cannot wedge DDC for
    /// the rest of the session.
    func hold(timeout: TimeInterval, onIdle: @escaping () -> Void) -> () -> Void {
        let hold = Hold(timeout: timeout)
        lock.lock()
        activeHolds.append(hold)
        let existing = Array(queues.values)
        hold.parked = existing.count
        lock.unlock()

        let idle = DispatchGroup()
        for queue in existing {
            idle.enter()
            queue.async {
                idle.leave()
                _ = hold.gate.wait(timeout: .now() + timeout)
            }
        }
        idle.notify(queue: DispatchQueue.global(qos: .userInitiated), execute: onIdle)

        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let parked = hold.parked
            hold.parked = 0
            self.activeHolds.removeAll { $0 === hold }
            self.lock.unlock()
            for _ in 0..<parked { hold.gate.signal() }
        }
    }
}
