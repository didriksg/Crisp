import Foundation
import IOKit
import IOKit.graphics

/// Native-size evidence read from the IORegistry. On Intel, raw IODisplayEDID is
/// commonly available. Apple Silicon DCP often withholds the raw bytes but publishes
/// the EDID-derived NativeFormatHorizontalPixels/NativeFormatVerticalPixels pair.
struct DetectedPanelResolution {
    let edid: PanelResolution?
    let registry: PanelResolution?
}

enum PanelResolutionDetector {
    static func detect(vendor: UInt32, product: UInt32, serial: UInt32) -> DetectedPanelResolution {
        var evidence = PanelResolutionEvidence()

        // Query only services that can carry display identity/native-format data.
        // A recursive walk from the IORegistry root visits thousands of unrelated
        // entries on Apple Silicon and can add hundreds of milliseconds per display.
        for serviceClass in displayServiceClasses {
            var iterator: io_iterator_t = 0
            let result = serviceClass.withCString { className in
                IOServiceGetMatchingServices(
                    kIOMainPortDefault, IOServiceMatching(className), &iterator)
            }
            guard result == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            var entry = IOIteratorNext(iterator)
            while entry != IO_OBJECT_NULL {
                let matched = properties(of: entry).map {
                    inspect($0, vendor: vendor, product: product, serial: serial,
                            evidence: &evidence)
                } ?? false
                IOObjectRelease(entry)

                // Intel commonly yields EDID from IODisplayConnect; DCP systems
                // commonly yield NativeFormat from AppleCLCD2/framebuffer nodes.
                // Once the matching node supplied either source, this is all the
                // current platform exposes and there is no reason to keep walking.
                if matched, evidence.hasResolution {
                    return DetectedPanelResolution(edid: evidence.edid, registry: evidence.registry)
                }
                entry = IOIteratorNext(iterator)
            }
        }

        return DetectedPanelResolution(edid: evidence.edid, registry: evidence.registry)
    }

    private static var displayServiceClasses: [String] {
#if arch(arm64)
        // DCP display properties live on AppleCLCD2 or its newer shim. Keep
        // IODisplayConnect as a fallback for third-party/DisplayLink drivers.
        ["AppleCLCD2", "IOMobileFramebufferShim", "IODisplayConnect"]
#else
        ["IODisplayConnect"]
#endif
    }

    private static func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            entry, &unmanaged, kCFAllocatorDefault, 0
        ) == KERN_SUCCESS, let dictionary = unmanaged?.takeRetainedValue() else { return nil }
        return dictionary as? [String: Any]
    }

    @discardableResult
    private static func inspect(_ properties: [String: Any], vendor: UInt32, product: UInt32,
                                serial: UInt32,
                                evidence: inout PanelResolutionEvidence) -> Bool {
        var matched = false
        if let data = properties[kIODisplayEDIDKey as String] as? Data,
           edidIdentityMatches(data, vendor: vendor, product: product, serial: serial) {
            matched = true
            evidence.recordEDID(data)
        }

        guard let attributes = properties["DisplayAttributes"] as? [String: Any],
              let identity = attributes["ProductAttributes"] as? [String: Any],
              identityMatches(identity, vendor: vendor, product: product, serial: serial)
        else { return matched }

        if let data = attributes[kIODisplayEDIDKey as String] as? Data {
            evidence.recordEDID(data)
        }

        // NativeFormat has appeared both directly under DisplayAttributes and
        // under ProductAttributes across DCP generations; accept either shape.
        if let width = int(attributes["NativeFormatHorizontalPixels"])
            ?? int(identity["NativeFormatHorizontalPixels"]),
           let height = int(attributes["NativeFormatVerticalPixels"])
            ?? int(identity["NativeFormatVerticalPixels"]) {
            evidence.recordRegistry(width: width, height: height)
        }
        return true
    }

    private static func identityMatches(_ identity: [String: Any], vendor: UInt32,
                                        product: UInt32, serial: UInt32) -> Bool {
        guard uint32(identity["LegacyManufacturerID"]) == vendor,
              uint32(identity["ProductID"]) == product else { return false }
        let candidateSerial = uint32(identity["SerialNumber"]) ?? 0
        return serial == 0 || candidateSerial == 0 || serial == candidateSerial
    }

    /// EDID manufacturer is big-endian; product and serial are little-endian.
    private static func edidIdentityMatches(_ data: Data, vendor: UInt32,
                                            product: UInt32, serial: UInt32) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else { return false }
        let edidVendor = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        let edidProduct = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        let edidSerial = UInt32(bytes[12]) | UInt32(bytes[13]) << 8
            | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        return edidVendor == vendor && edidProduct == product
            && (serial == 0 || edidSerial == 0 || serial == edidSerial)
    }

    private static func uint32(_ value: Any?) -> UInt32? {
        if let value = value as? UInt32 { return value }
        if let value = value as? Int { return UInt32(truncatingIfNeeded: value) }
        if let value = value as? NSNumber { return value.uint32Value }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? UInt32 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
