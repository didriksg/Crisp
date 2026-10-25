import Foundation
import IOKit

/// Sends one DDC/CI message, twice for a monitor that ignores the first copy (docs/ddc-notes.md).
enum DDCMessage {
    /// Alienware AW2725DF and AW3423DWF.
    static func repeats(vendor: UInt32, model: UInt32) -> Bool {
        vendor == 0x10AC && (model == 0xA252 || model == 0xA212)
    }

    /// Doubled Set VCP writes stop these monitors' DDC until a dock replug, so only
    /// input select (VCP 0x60, one write per switch) reaches them.
    static func allows(vendor: UInt32, model: UInt32, command: UInt8) -> Bool {
        !repeats(vendor: vendor, model: model) || command == 0x60
    }

    /// The wait before the reply read, and its length. With 40 ms, 12 bytes and no gaps
    /// before the copies, doubled reads stopped these monitors' DDC within 34 requests.
    static func replyShape(vendor: UInt32, model: UInt32) -> (wait: TimeInterval, length: Int) {
        repeats(vendor: vendor, model: model) ? (0.05, 11) : (0.04, 12)
    }

    static func send(vendor: UInt32, model: UInt32, _ write: () -> IOReturn) -> IOReturn {
        guard repeats(vendor: vendor, model: model) else { return write() }
        Thread.sleep(forTimeInterval: 0.01)
        let first = write()
        // A deaf channel can take seconds per call, so it gets one call only.
        guard first == kIOReturnSuccess else { return first }
        Thread.sleep(forTimeInterval: 0.01)
        return write()
    }
}
