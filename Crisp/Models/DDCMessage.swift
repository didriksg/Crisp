import IOKit

/// Sends one DDC/CI message, twice for a monitor that ignores the first copy (docs/ddc-notes.md).
enum DDCMessage {
    /// The AW3423DWF ignores the first copy too, but repeats stop its DDC until a replug.
    static func repeats(vendor: UInt32, model: UInt32) -> Bool {
        vendor == 0x10AC && model == 0xA252  // Alienware AW2725DF
    }

    static func send(vendor: UInt32, model: UInt32, _ write: () -> IOReturn) -> IOReturn {
        let first = write()
        // A deaf channel can take seconds per call, so it gets one call only.
        guard first == kIOReturnSuccess, repeats(vendor: vendor, model: model) else { return first }
        return write()
    }
}
