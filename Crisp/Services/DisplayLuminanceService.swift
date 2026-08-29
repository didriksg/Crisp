import Foundation
import CoreGraphics
import IOKit

private let _CoreDisplayCreateInfoDictionary: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?)? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
          let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
    return unsafeBitCast(
        symbol,
        to: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?).self
    )
}()

/// Reads the display's absolute-luminance ceiling used to put built-in and DDC
/// brightness on one scale. Apple publishes SDR nits through CoreDisplay; an
/// external monitor publishes CTA/EDID max luminance in IORegistry as 16.16.
enum DisplayLuminanceService {
    static func maximumSDRNits(
        displayID: CGDirectDisplayID,
        isBuiltin: Bool,
        vendor: UInt32,
        model: UInt32,
        serial: UInt32
    ) -> Double? {
        if isBuiltin, let value = builtinMaximumSDRNits(displayID: displayID) {
            return value
        }
        guard !isBuiltin else { return nil }
        return externalMaximumNits(vendor: vendor, model: model, serial: serial)
    }

    private static func builtinMaximumSDRNits(displayID: CGDirectDisplayID) -> Double? {
        guard let dictionary = _CoreDisplayCreateInfoDictionary?(displayID)?.takeRetainedValue()
                as? [String: Any] else { return nil }
        // Non-reference is the normal Apple XDR preset; the reference peak
        // is the fallback for fixed-luminance reference presets.
        for key in ["NonReferencePeakSDRLuminance", "ReferencePeakSDRLuminance"] {
            if let value = number(dictionary[key]), value > 0 { return value }
        }
        return nil
    }

    private static func externalMaximumNits(vendor: UInt32, model: UInt32, serial: UInt32) -> Double? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let attributes = IORegistryEntryCreateCFProperty(
                    entry,
                    "DisplayAttributes" as CFString,
                    kCFAllocatorDefault,
                    0
                  )?.takeRetainedValue() as? [String: Any],
                  let product = attributes["ProductAttributes"] as? [String: Any],
                  number(product["LegacyManufacturerID"]) == Double(vendor),
                  number(product["ProductID"]) == Double(model) else { continue }

            let registrySerial = number(product["SerialNumber"]) ?? 0
            if serial != 0, registrySerial != 0, Double(serial) != registrySerial { continue }
            guard let luminance = attributes["Luminance"] as? [String: Any],
                  let raw = number(luminance["Max"]), raw > 0 else { continue }
            // CoreDisplay publishes CTA luminance as unsigned 16.16 fixed point.
            let nits = raw > 10_000 ? raw / 65_536.0 : raw
            if nits >= 40, nits <= 10_000 { return nits }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? UInt32 { return Double(value) }
        return nil
    }
}
