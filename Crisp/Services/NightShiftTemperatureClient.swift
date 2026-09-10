import Foundation

/// Runtime-only bridge, like the existing Night Shift toggle. No private framework
/// linkage or stored preference writes; CoreBrightness commits the system setting.
final class NightShiftTemperatureClient: @unchecked Sendable {
    private let client: NSObject
    private let queue = DispatchQueue(label: "com.crisp.nightShiftTemperature", qos: .userInitiated)
    private let getSelector = NSSelectorFromString("getStrength:")
    private let setSelector = NSSelectorFromString("setStrength:commit:")

    init?(client: NSObject) {
        guard client.responds(to: getSelector), client.responds(to: setSelector) else { return nil }
        self.client = client
    }

    func read() async -> Float? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                typealias Get = @convention(c) (NSObject, Selector, UnsafeMutablePointer<Float>) -> Bool
                var value: Float = 0
                let success = unsafeBitCast(client.method(for: getSelector), to: Get.self)(client, getSelector, &value)
                continuation.resume(returning: success ? value : nil)
            }
        }
    }

    func write(_ value: Float) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                typealias Set = @convention(c) (NSObject, Selector, Float, Bool) -> Bool
                let success = unsafeBitCast(client.method(for: setSelector), to: Set.self)(client, setSelector, value, true)
                continuation.resume(returning: success)
            }
        }
    }
}
