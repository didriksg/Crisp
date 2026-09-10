import Foundation
import Combine

/// The system owns the strength and schedule. Keep only a live UI snapshot here.
/// Reads cannot pull the thumb backward during a drag; writes are serialized and
/// coalesced so a slow CoreBrightness round-trip does not queue every mouse event.
@MainActor
final class NightShiftTemperatureController: ObservableObject {
    @Published private(set) var strength: Double?

    private let read: @Sendable () async -> Float?
    private let write: @Sendable (Float) async -> Bool
    private var revision: UInt64 = 0
    private var isEditing = false
    private var isWriting = false
    private var pendingStrength: Float?

    init(read: @escaping @Sendable () async -> Float?, write: @escaping @Sendable (Float) async -> Bool) {
        self.read = read
        self.write = write
    }

    func refresh() async {
        guard !isEditing, !isWriting else { return }
        revision &+= 1
        let request = revision
        let value = await read()
        guard request == revision, !isEditing, !isWriting else { return }
        strength = value.flatMap { $0.isFinite ? Double(min(1, max(0, $0))) : nil }
    }

    func setEditing(_ editing: Bool) {
        isEditing = editing
        revision &+= 1
    }

    func setStrength(_ value: Double) async {
        guard value.isFinite else { return }
        let target = Float(min(1, max(0, value)))
        revision &+= 1
        strength = Double(target)
        pendingStrength = target
        guard !isWriting else { return }
        isWriting = true
        while let next = pendingStrength {
            pendingStrength = nil
            // Always read back after the last write, including failures. A failed
            // read disables the control instead of displaying an invented value.
            _ = await write(next)
        }
        isWriting = false
        await refresh()
    }
}
