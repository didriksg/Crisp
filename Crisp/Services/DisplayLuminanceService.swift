import Foundation
import CoreGraphics
import IOKit
import os

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
    private static let log = Logger(subsystem: "com.crisp.app", category: "brightness")
    /// Below 40 nits nothing is a display panel; above 10 000 nothing is a nominal peak.
    private static let plausibleNits: ClosedRange<Double> = 40...10_000

    static func maximumSDRNits(displayID: CGDirectDisplayID, isBuiltin: Bool) -> Double? {
        let nits = isBuiltin ? builtinMaximumSDRNits(displayID: displayID) : externalMaximumNits(displayID: displayID)
        log.notice("display \(displayID, privacy: .public): nominal peak \(nits.map { String(Int($0)) } ?? "unknown", privacy: .public) nits, combined brightness \(nits == nil ? "proportional" : "by luminance", privacy: .public)")
        return nits
    }

    private static func builtinMaximumSDRNits(displayID: CGDirectDisplayID) -> Double? {
        guard let dictionary = _CoreDisplayCreateInfoDictionary?(displayID)?.takeRetainedValue()
                as? [String: Any] else { return nil }
        // Non-reference is the normal Apple XDR preset; the reference peak
        // is the fallback for fixed-luminance reference presets.
        for key in ["NonReferencePeakSDRLuminance", "ReferencePeakSDRLuminance"] {
            if let value = number(dictionary[key]), plausibleNits.contains(value) { return value }
        }
        return nil
    }

    /// The framebuffer node for an external display is found the way DDC pairing
    /// finds its channel: the same identity parser and the same matcher, over the
    /// same DisplayAttributes nodes in traversal order, so a monitor that pairs for
    /// brightness reads its luminance from the same node.
    private static func externalMaximumNits(displayID: CGDirectDisplayID) -> Double? {
        let nodes = registryNodes()
        guard !nodes.isEmpty else { return nil }
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let displays = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.map {
            (id: $0, identity: DDCServiceMatcher.Identity(
                vendor: CGDisplayVendorNumber($0), product: CGDisplayModelNumber($0), serial: CGDisplaySerialNumber($0)))
        }
        let result = DDCServiceMatcher.match(services: nodes.map(\.identity), displays: displays)
        guard let index = result.byDisplayID[displayID] else { return nil }
        return nodes[index].nits
    }

    private struct Node {
        let identity: DDCServiceMatcher.Identity?
        let nits: Double?
    }

    /// One walk serves every display of a reconfiguration: loadDetails asks once
    /// per display within the same second, and the walk covers the whole service
    /// plane (about half a second on this Mac).
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var nodes: [Node] = []
        var at = Date.distantPast
    }
    private static let cache = Cache()

    private static func registryNodes() -> [Node] {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if Date().timeIntervalSince(cache.at) < 5 { return cache.nodes }
        var nodes: [Node] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            if let attributes = IORegistryEntryCreateCFProperty(
                    entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
               )?.takeRetainedValue() as? [String: Any],
               let product = attributes["ProductAttributes"] as? [String: Any] {
                nodes.append(Node(identity: DDCService.displayIdentity(from: product),
                                  nits: maximumNits(in: attributes["Luminance"] as? [String: Any])))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        cache.nodes = nodes
        cache.at = Date()
        return nodes
    }

    /// CoreDisplay publishes CTA luminance as unsigned 16.16 fixed point; on an HDR
    /// monitor it is the HDR peak, which is why the settings keep a fine-tuning ratio.
    private static func maximumNits(in luminance: [String: Any]?) -> Double? {
        guard let raw = number(luminance?["Max"]), raw > 0 else { return nil }
        let nits = raw > 10_000 ? raw / 65_536.0 : raw
        return plausibleNits.contains(nits) ? nits : nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}
