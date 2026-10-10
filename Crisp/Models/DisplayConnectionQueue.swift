/// Runs display connection changes one at a time, in call order. Each operation starts only
/// after the one before it has returned, so a check inside it (the last-screen guard) sees
/// what the earlier change did.
@MainActor
final class DisplayConnectionQueue {
    private var tail: Task<Void, Never>?

    func run<Output: Sendable>(_ operation: @escaping @MainActor () async -> Output) async -> Output {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}
