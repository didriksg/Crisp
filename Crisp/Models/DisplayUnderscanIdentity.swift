import CoreGraphics
import Foundation

/// Immutable snapshot of the hardware identity attributes used to build stable per-display
/// underscan storage keys without relying on the volatile `CGDirectDisplayID`.
struct DisplayUnderscanDescriptor: Equatable, Hashable, Sendable {
    let displayID: CGDirectDisplayID
    let cgUUID: String?
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32
    /// Physical port/channel location (e.g. from `kIODisplayLocationKey`), used to
    /// disambiguate identical monitor models that report the same vendor/model/serial.
    let channelLocation: String?
    let isBuiltin: Bool
    let isVirtual: Bool
    let displayName: String

    init(
        displayID: CGDirectDisplayID,
        cgUUID: String?,
        vendorNumber: UInt32,
        modelNumber: UInt32,
        serialNumber: UInt32,
        channelLocation: String? = nil,
        isBuiltin: Bool,
        isVirtual: Bool = false,
        displayName: String
    ) {
        self.displayID = displayID
        self.cgUUID = cgUUID
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.channelLocation = channelLocation
        self.isBuiltin = isBuiltin
        self.isVirtual = isVirtual
        self.displayName = displayName
    }
}

/// Computes stable per-display identifiers for underscan persistence.
///
/// Rules:
/// - Never keys solely on `CGDirectDisplayID`, which changes across reconnects and reboots.
/// - Uses the CoreGraphics display UUID when valid and non-colliding.
/// - When identical monitor models share the same EDID identity (e.g. `serialNumber == 0`
///   and matching vendor/model/UUID), appends a deterministic hash of `channelLocation` so
///   the monitors never silently share one underscan setting.
/// - Falls back to `v<vendor>-m<model>-s<serial>` (+ location hash if available) when
///   `CGDisplayCreateUUIDFromDisplayID` is unavailable.
enum DisplayUnderscanIdentity {
    private static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    /// Normalized valid UUID string, or nil when absent/placeholder.
    static func normalizedUUID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.uppercased() != zeroUUID else {
            return nil
        }
        return trimmed.uppercased()
    }

    /// Base hardware key before identical-model port disambiguation.
    static func baseKey(for descriptor: DisplayUnderscanDescriptor) -> String {
        if let uuid = normalizedUUID(descriptor.cgUUID) {
            return uuid
        }
        let vendorHex = String(format: "%04x", descriptor.vendorNumber)
        let modelHex = String(format: "%04x", descriptor.modelNumber)
        let serialHex = String(format: "%08x", descriptor.serialNumber)
        return "edid-v\(vendorHex)-m\(modelHex)-s\(serialHex)"
    }

    /// Deterministic 64-bit FNV-1a hex digest for a physical channel location string.
    static func locationToken(for location: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in location.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    /// Computes the stable storage key for `descriptor` in the context of `allLive` displays.
    ///
    /// When two live external displays share the same base key or are identical models
    /// (`vendor == vendor`, `model == model`, `serial == 0`), disambiguates using
    /// `channelLocation` (when available) so each physical monitor keeps independent settings.
    static func stableKey(
        for descriptor: DisplayUnderscanDescriptor,
        among allLive: [DisplayUnderscanDescriptor]
    ) -> String {
        let base = baseKey(for: descriptor)
        let hasDuplicateBase = allLive.filter { baseKey(for: $0) == base }.count > 1
        let hasIdenticalUnserializedPeer = !descriptor.isBuiltin
            && descriptor.serialNumber == 0
            && descriptor.vendorNumber != 0
            && allLive.filter {
                !$0.isBuiltin
                    && $0.vendorNumber == descriptor.vendorNumber
                    && $0.modelNumber == descriptor.modelNumber
                    && $0.serialNumber == 0
            }.count > 1

        if let location = descriptor.channelLocation, !location.isEmpty,
           hasDuplicateBase || hasIdenticalUnserializedPeer || normalizedUUID(descriptor.cgUUID) == nil {
            return "\(base)@loc-\(locationToken(for: location))"
        }

        if hasDuplicateBase {
            // Last-resort deterministic fallback when two live displays report identical
            // UUIDs and no IORegistry channel location is exposed.
            return "\(base)@id-\(descriptor.displayID)"
        }

        return base
    }

    /// Legacy key format using volatile `CGDirectDisplayID`, consulted only for safe
    /// one-time migration of live displays.
    static func legacyDisplayIDKey(for displayID: CGDirectDisplayID) -> String {
        "crisp.underscan.display.\(displayID)"
    }
}
