import Foundation

/// Shared utilities for wrapping blocking CoreGraphics calls.
enum CGHelpers {
    enum TimedResult<T: Sendable>: Sendable {
        case completed(T)
        case timedOut
    }

    /// WindowServer display transactions are process-global. Keeping their
    /// blocking bodies on one queue prevents a timed-out operation from
    /// overlapping a later transaction while it continues underneath.
    private static let operationQueue = DispatchQueue(
        label: "com.crisp.cg-operations", qos: .userInitiated)

    /// Runs a blocking operation on a background thread with a timeout.
    ///
    /// Operations execute serially. A request that times out while waiting for
    /// an earlier blocking body is skipped when it reaches the front, rather
    /// than running a stale transaction after its caller has moved on.
    ///
    /// This is useful for any CoreGraphics / WindowServer IPC call that can
    /// hang indefinitely (e.g. `CGCompleteDisplayConfiguration`,
    /// `CGVirtualDisplay.apply(_:)`).
    ///
    /// - Parameters:
    ///   - seconds:   Maximum time to wait before returning `fallback`.
    ///   - fallback:  Value returned on timeout.
    ///   - operation: The blocking work to execute off-thread.
    /// - Returns: The operation's result, or `fallback` on timeout.
    static func runWithTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { cont in
            let lock = NSLock()
            var didResume = false

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
                cont.resume(returning: fallback)
            }

            operationQueue.async {
                lock.lock()
                // The request expired before its blocking body started. Do not
                // run it later: that would apply stale display state.
                guard !didResume else { lock.unlock(); return }
                lock.unlock()

                let result = operation()
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
                cont.resume(returning: result)
            }

        }
    }

    /// Queues mandatory compensating work that may not be skipped, but still
    /// returns `.timedOut` to its caller at the deadline. If the queue drains
    /// later, the operation runs and reports through `lateCompletion`, allowing
    /// the owner to repair its state without leaving an async UI task hung.
    static func runMandatoryWithTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () -> T,
        lateCompletion: @escaping @Sendable (T) -> Void
    ) async -> TimedResult<T> {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didResume = false

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
                continuation.resume(returning: .timedOut)
            }

            operationQueue.async {
                let result = operation()
                lock.lock()
                if didResume {
                    lock.unlock()
                    lateCompletion(result)
                } else {
                    didResume = true
                    lock.unlock()
                    continuation.resume(returning: .completed(result))
                }
            }
        }
    }
}
