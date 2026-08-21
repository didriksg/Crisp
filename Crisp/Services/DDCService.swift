import Foundation
import Combine
import CoreGraphics
import IOKit
import IOKit.i2c
import IOKit.graphics
import os.log

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

private let coreDisplayCreateInfoDictionary:
    (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?)? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else {
            return nil
        }
        return unsafeBitCast(
            symbol,
            to: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?).self
        )
    }()

/// DDC/CI I2C communication service for external displays.
/// Supports two hardware paths:
///   - ARM64 (Apple Silicon): IOAVService via DCPAVServiceProxy
///   - x86_64 (Intel):        IOFramebuffer I2C via IOFBCopyI2CInterfaceForBus
/// All I2C operations run on a private background queue to avoid blocking UI.
final class DDCService: ObservableObject, @unchecked Sendable {
    static let shared = DDCService()

    // VCP feature codes (DDC/CI standard)
    static let brightnessVCP: UInt8 = 0x10
    static let contrastVCP: UInt8   = 0x12
    static let volumeVCP: UInt8     = 0x62

    /// Diagnostics for support threads. Transitions and failures go out at
    /// notice/error (persisted; reporters run `log show --predicate
    /// 'subsystem == "com.crisp.app"'`), per-write chatter at debug (memory
    /// only). Display IDs and vendor/product pair with the pairing lines;
    /// serials never appear.
    private static let log = Logger(subsystem: "com.crisp.app", category: "ddc")
    /// A single I2C op slower than this is logged at notice (issue #72: 12 s reads).
    private static let slowOpThresholdMs = 500.0

    private static func millisSince(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private static func hex(_ code: UInt8) -> String { String(format: "0x%02X", code) }
    /// Last logged pairing outcome, guarded by avServiceLock; reset on the map flush.
    private var lastPairingSummary = ""
    static let powerVCP: UInt8      = 0xD6

    private let operationQueues = DDCOperationQueuePool()

    // MARK: - VCP Read Cache (5-second TTL)

    private struct VCPCacheEntry {
        let current: UInt16
        let max: UInt16
        let timestamp: Date
        var isExpired: Bool { Date().timeIntervalSince(timestamp) > 5.0 }
    }

    private var vcpCache: [CGDirectDisplayID: [UInt8: VCPCacheEntry]] = [:]
    private let cacheLock = NSLock()

    // MARK: - IOAVService Cache (ARM64 only)

#if arch(arm64)
    private var avServiceCache: [CGDirectDisplayID: IOAVServiceRef] = [:]
    /// When the last registry walk found no channel for a display. A walk test-reads every
    /// DCPAVServiceProxy, and one whose display is off or wedged holds the DCP's I2C engine
    /// for about six seconds before it fails, so re-walking on every op for an unpaired
    /// display kept that engine busy for most of a refresh. WindowServer's enable of a
    /// display waits behind an I2C transaction on that engine, and the whole machine waits
    /// with it (issue #33's shape; measured here as a 6 s freeze on a reconnect that landed
    /// inside a 6 s volume read). Remembering the miss briefly turns six walks per refresh
    /// into one and still lets a monitor that answers late get picked up. Under avServiceLock.
    private var noChannelSince: [CGDirectDisplayID: Date] = [:]
    private let noChannelRetryInterval: TimeInterval = 20
    private let avServiceLock = NSLock()
    /// Ordered list of all external AVServices found during last enumeration.
    private var allExternalAVServices: [IOAVServiceRef] = []
#endif

    private init() {}

    // MARK: - ARM64 IOAVService Path

#if arch(arm64)
    // MARK: - ARM64 IORegistry-based AVService matching

    /// Mapping warning exposed to UI when more than one external display is connected
    /// and we fall back to traversal-order AVService assignment.
    @Published var mappingWarning: String? = nil

    /// Builds a display→AVService map by walking the IOService registry depth-first.
    ///
    /// On Apple Silicon the DDC channel (DCPAVServiceProxy) and the display's identity
    /// (DisplayAttributes → ProductAttributes) live in *sibling* subtrees under the same
    /// dispextN node, the identity is NOT an ancestor of the AVService, so an upward
    /// parent-chain walk never finds it (the old approach always fell through to a
    /// sorted-CGDirectDisplayID index, which mis-pairs channels and drives the wrong
    /// monitor). A depth-first traversal instead visits each display's framebuffer
    /// identity immediately before that same display's DCPAVServiceProxy, so every
    /// AVService can be associated with the most recently seen identity. This is the
    /// same proximity strategy MonitorControl uses.
    ///
    /// Matching order:
    ///   1. Stable CoreDisplay/IORegistry location.
    ///   2. Identity: vendor+product+non-zero serial, then vendor+product.
    ///   3. Traversal-order fallback for anything identity matching missed (e.g. two
    ///      identical monitors that share vendor/product/serial). This preserves correct
    ///      pairing far better than the old sorted-index because the AVService order
    ///      follows the framebuffer order within the same subtree.
    ///
    /// Returns the map plus the external AVServices in traversal order.
    private func buildAVServiceMapByProximity() -> (map: [CGDirectDisplayID: IOAVServiceRef], ordered: [IOAVServiceRef]) {
        // External CG displays we need to map.
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        let externalIDs = (0..<Int(displayCount))
            .map { displayIDs[$0] }
            .filter { CGDisplayIsBuiltin($0) == 0 }
        guard !externalIDs.isEmpty else { return ([:], []) }

        // Depth-first walk of the entire IOService plane.
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root, kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return ([:], []) }
        defer { IOObjectRelease(iterator) }

        var ordered: [IOAVServiceRef] = []
        var identities: [DDCServiceMatcher.Identity?] = []
        var lastIdentity: DDCServiceMatcher.Identity? = nil

        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            // Update the running identity whenever a framebuffer node exposes one.
            if let da = IORegistryEntryCreateCFProperty(
                    entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
               )?.takeRetainedValue() as? [String: Any],
               let pa = da["ProductAttributes"] as? [String: Any],
               let id = displayIdentity(from: pa, location: ioRegistryPath(for: entry)) {
                lastIdentity = id
            }

            // Enumerate external channels without probing them. Some monitors block an
            // unsolicited read for seconds; real VCP operations decide capability.
            if ioClassName(entry) == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(
                    entry, "Location" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? String
                // Some drivers omit "Location"; still attempt those. Skip explicit non-External.
                if location == nil || location == "External",
                   let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) {
                    ordered.append(avService)
                    identities.append(lastIdentity)
                }
            }

            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }

        // Strategy 1 + Strategy 2 + the ambiguity flag live in the pure, headless-testable
        // `DDCServiceMatcher` (Crisp/Models/DDCServiceMatcher.swift). Its inputs are the
        // IORegistry identities collected above (already `DDCServiceMatcher.Identity`) and
        // the CoreGraphics display list; the matching semantics are byte-for-byte those the
        // inline code used previously.
        let displays: [(id: CGDirectDisplayID, identity: DDCServiceMatcher.Identity)] = externalIDs.map {
            (id: $0, identity: DDCServiceMatcher.Identity(
                vendor: CGDisplayVendorNumber($0),
                product: CGDisplayModelNumber($0),
                serial: CGDisplaySerialNumber($0),
                location: coreDisplayLocation(for: $0)))
        }
        let result = DDCServiceMatcher.match(services: identities, displays: displays)

        // Log the pairing once per outcome: with no channel at all the walk
        // re-runs on every DDC op, and six identical lines per probe help nobody.
        var lines: [(error: Bool, text: String)] = []
        for display in displays {
            let vendorProduct = String(format: "vendor 0x%04X product 0x%04X",
                                       display.identity.vendor, display.identity.product)
            if let index = result.byDisplayID[display.id] {
                let byIdentity = identities[index].map {
                    $0.vendor == display.identity.vendor && $0.product == display.identity.product
                } ?? false
                lines.append((false, "pairing: display \(display.id) (\(vendorProduct)) -> channel \(index) of \(ordered.count) by \(byIdentity ? "identity" : "traversal order")"))
            } else {
                lines.append((true, "pairing: display \(display.id) (\(vendorProduct)) -> no DDC channel (\(ordered.count) found)"))
            }
        }
        let summary = lines.map(\.text).joined(separator: "\n")
        let changed = avServiceLock.withLock { () -> Bool in
            defer { lastPairingSummary = summary }
            return summary != lastPairingSummary
        }
        if changed {
            for line in lines {
                if line.error {
                    Self.log.error("\(line.text, privacy: .public)")
                } else {
                    Self.log.notice("\(line.text, privacy: .public)")
                }
            }
        }

        var map: [CGDirectDisplayID: IOAVServiceRef] = [:]
        // Safe: each CGDirectDisplayID key is assigned exactly once, so the unspecified
        // Dictionary iteration order cannot drop or overwrite an entry.
        for (displayID, serviceIndex) in result.byDisplayID {
            map[displayID] = ordered[serviceIndex]
        }

        // Warn only when the fallback had to guess among >1 indistinguishable displays.
        let warning = result.ambiguous
            ? "Multiple external displays: DDC identity matching failed; using traversal order"
            : nil
        DispatchQueue.main.async { self.mappingWarning = warning }

        return (map, ordered)
    }

    private func coreDisplayLocation(for displayID: CGDirectDisplayID) -> String? {
        guard let dictionary = coreDisplayCreateInfoDictionary?(displayID)?.takeRetainedValue()
                as NSDictionary? else { return nil }
        return dictionary[kIODisplayLocationKey] as? String
    }

    private func ioRegistryPath(for entry: io_service_t) -> String? {
        let path = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { path.deallocate() }
        guard IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS else {
            return nil
        }
        return String(cString: path)
    }

    /// Extracts vendor/product/serial from a ProductAttributes dictionary. The numeric
    /// LegacyManufacturerID / ProductID / SerialNumber match CGDisplayVendorNumber /
    /// CGDisplayModelNumber / CGDisplaySerialNumber for the same physical display.
    private func displayIdentity(
        from productAttributes: [String: Any],
        location: String? = nil
    ) -> DDCServiceMatcher.Identity? {
        func u32(_ value: Any?) -> UInt32? {
            if let v = value as? UInt32 { return v }
            if let v = value as? Int { return UInt32(bitPattern: Int32(truncatingIfNeeded: v)) }
            if let v = value as? NSNumber { return v.uint32Value }
            return nil
        }
        guard let vendor = u32(productAttributes["LegacyManufacturerID"]),
              let product = u32(productAttributes["ProductID"]) else { return nil }
        return DDCServiceMatcher.Identity(
            vendor: vendor,
            product: product,
            serial: u32(productAttributes["SerialNumber"]) ?? 0,
            location: location
        )
    }

    /// Returns the IOKit class name of a registry entry.
    private func ioClassName(_ entry: io_service_t) -> String? {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { buf.deallocate() }
        guard IOObjectGetClass(entry, buf) == KERN_SUCCESS else { return nil }
        return String(cString: buf)
    }

    /// Finds the IOAVService for the given display. Caches the result per display.
    /// Returns nil if no AVService is found (built-in displays, or displays
    /// that don't support DDC over the Apple Silicon AV path).
    ///
    /// Matching strategy: depth-first IOService traversal that pairs each DDC channel
    /// with the display identity seen closest to it in the registry (see
    /// buildAVServiceMapByProximity), then vendor/product/serial matching against the
    /// CoreGraphics display list, with a traversal-order fallback.
    private func findAVService(for displayID: CGDirectDisplayID) -> IOAVServiceRef? {
        // Fast path: return cached service if present, or a recent miss as nil.
        avServiceLock.lock()
        if let cached = avServiceCache[displayID] {
            avServiceLock.unlock()
            return cached
        }
        if let since = noChannelSince[displayID], Date().timeIntervalSince(since) < noChannelRetryInterval {
            avServiceLock.unlock()
            return nil
        }
        avServiceLock.unlock()

        // Slow path: enumerate the IOService registry depth-first, pairing each external
        // DDC channel with the nearest preceding display identity.
        let (serviceMap, ordered) = buildAVServiceMapByProximity()

        guard !ordered.isEmpty else {
            avServiceLock.withLock { noChannelSince[displayID] = Date() }
            return nil
        }

        // Re-check cache (double-checked locking) in case another thread enumerated
        // and populated the cache while we were enumerating without the lock held.
        avServiceLock.lock()
        if let cached = avServiceCache[displayID] {
            avServiceLock.unlock()
            return cached
        }
        allExternalAVServices = ordered
        for (extID, avService) in serviceMap {
            avServiceCache[extID] = avService
        }
        let result = avServiceCache[displayID]
        noChannelSince[displayID] = result == nil ? Date() : nil
        avServiceLock.unlock()

        return result
    }

    /// Invalidates the cached IOAVService for the given display (e.g. after display reconnect).
    func invalidateAVServiceCache(for displayID: CGDirectDisplayID) {
        avServiceLock.lock()
        avServiceCache.removeValue(forKey: displayID)
        avServiceLock.unlock()
    }

    /// ARM64 DDC write: send a Set VCP command via IOAVService.
    /// Buffer layout (bytes sent after the device address / offset arguments):
    ///   [0x84, 0x03, vcpCode, valueHigh, valueLow, checksum]
    /// Checksum = XOR of 0x50 (0x51 XOR 0x01) with all preceding buffer bytes.
    private func arm64Write(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        guard let avService = findAVService(for: displayID) else {
            Self.log.debug("write \(Self.hex(command), privacy: .public) display \(displayID, privacy: .public): no DDC channel")
            return false
        }

        let valueHigh = UInt8((value >> 8) & 0xFF)
        let valueLow  = UInt8(value & 0xFF)
        // Checksum seed: 0x50 = 0x6E (DDC destination) XOR 0x51 (sub-address used by IOAVServiceWriteI2C)
        // then XOR with each byte in the payload.
        var checksum  = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x84, 0x03, command, valueHigh, valueLow]
        for b in payload { checksum ^= b }

        var buf: [UInt8] = payload + [checksum]
        let ret = IOAVServiceWriteI2C(avService, 0x37, 0x51, &buf, UInt32(buf.count))
        if ret != kIOReturnSuccess {
            Self.log.debug("write \(Self.hex(command), privacy: .public)=\(value, privacy: .public) display \(displayID, privacy: .public): I2C error \(String(format: "0x%08X", ret), privacy: .public)")
        }
        return ret == kIOReturnSuccess
    }

    /// ARM64 DDC read: send a Get VCP request then read the response via IOAVService.
    /// Request layout: [0x82, 0x01, vcpCode, checksum]
    /// Response bytes 4-7 carry: [maxHigh, maxLow, curHigh, curLow]
    private func arm64Read(displayID: CGDirectDisplayID, command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let avService = findAVService(for: displayID) else {
            Self.log.debug("read \(Self.hex(command), privacy: .public) display \(displayID, privacy: .public): no DDC channel")
            return nil
        }
        // Every failure class gets its own line: this is what a reporter's log
        // capture answers instead of a round of questions (docs/ddc-notes.md).
        func fail(_ reason: String) -> (current: UInt16, max: UInt16)? {
            Self.log.notice("read \(Self.hex(command), privacy: .public) display \(displayID, privacy: .public): \(reason, privacy: .public)")
            return nil
        }

        // Build and send the VCP Get Request packet
        var requestChecksum = UInt8(0x6E ^ 0x51)
        let requestPayload: [UInt8] = [0x82, 0x01, command]
        for b in requestPayload { requestChecksum ^= b }
        var requestBuf: [UInt8] = requestPayload + [requestChecksum]

        let writeRet = IOAVServiceWriteI2C(avService, 0x37, 0x51, &requestBuf, UInt32(requestBuf.count))
        guard writeRet == kIOReturnSuccess else {
            return fail("request write I2C error \(String(format: "0x%08X", writeRet))")
        }

        // Wait for the display to prepare its DDC/CI reply (~40ms per spec)
        Thread.sleep(forTimeInterval: 0.04)

        // Read the VCP reply
        var replyBuf = [UInt8](repeating: 0, count: 12)
        let readRet = IOAVServiceReadI2C(avService, 0x37, 0x51, &replyBuf, UInt32(replyBuf.count))
        guard readRet == kIOReturnSuccess else {
            return fail("reply read I2C error \(String(format: "0x%08X", readRet))")
        }

        // DDC/CI VCP reply format (IOAVService variant):
        //   replyBuf[0] = source address (0x6E)
        //   replyBuf[1] = length byte (0x88 = 0x80 | 8)
        //   replyBuf[2] = 0x02 (Get VCP Feature Reply opcode)
        //   replyBuf[3] = result code (0x00 = no error)
        //   replyBuf[4] = VCP opcode echo
        //   replyBuf[5] = VCP type code
        //   replyBuf[6] = max value high byte
        //   replyBuf[7] = max value low byte
        //   replyBuf[8] = current value high byte
        //   replyBuf[9] = current value low byte
        //  replyBuf[10] = checksum
        guard replyBuf.count >= 10 else { return nil }

        // Validate the reply frame before trusting the payload. Many monitors ack the
        // I2C read (readRet == success) but return stale EDID bytes or a null frame
        // instead of a real VCP reply, especially over the Apple Silicon AV path.
        // Reading bytes 6–9 from such garbage yields a bogus "max" (e.g. 8824 instead
        // of 100), which then compresses the usable brightness range so the top of the
        // slider does nothing. Require the DDC/CI reply signature and the VCP echo.
        guard replyBuf[0] == 0x6E,      // source address
              replyBuf[2] == 0x02,      // Get VCP Feature Reply opcode
              replyBuf[3] == 0x00,      // result code: no error
              replyBuf[4] == command    // echo of the VCP code we asked for
        else {
            let head = replyBuf.prefix(6).map { String(format: "%02X", $0) }.joined(separator: " ")
            return fail("bad reply header [\(head)] (null frame, echo, or stale EDID bytes)")
        }

        // Header bytes alone are only 4 bytes of protection: a wedged DDC
        // controller (seen on the AOC Q27G3XMN) streams noise that acks reads,
        // and a lucky frame can pass the signature with garbage value bytes,
        // poisoning the stored max. The DDC/CI checksum (0x50 seed XORed over
        // bytes 0-9) must match byte 10 before the payload is trusted.
        var expectedChecksum = UInt8(0x50)
        for i in 0...9 { expectedChecksum ^= replyBuf[i] }
        guard expectedChecksum == replyBuf[10] else {
            return fail("bad reply checksum")
        }

        let maxVal = (UInt16(replyBuf[6]) << 8) | UInt16(replyBuf[7])
        let curVal = (UInt16(replyBuf[8]) << 8) | UInt16(replyBuf[9])
        // A zero max is also invalid (would make every write 0); reject it.
        guard maxVal > 0 else {
            return fail("reply carries max 0")
        }
        Self.log.notice("read \(Self.hex(command), privacy: .public) display \(displayID, privacy: .public): ok \(curVal, privacy: .public)/\(maxVal, privacy: .public)")
        return (current: curVal, max: maxVal)
    }
#endif

    // MARK: - Intel (x86_64) IOFramebuffer Path

    /// Finds the IOFramebuffer service for a given external display.
    /// Returns a retained io_service_t, caller must IOObjectRelease.
    private func framebufferService(for displayID: CGDirectDisplayID) -> io_service_t? {
        // Strategy 1: Use CGDisplayIOServicePort (deprecated but functional on macOS 15)
        let servicePort = CGDisplayIOServicePort(displayID)
        if servicePort != MACH_PORT_NULL && servicePort != 0 {
            var parent: io_service_t = 0
            if IORegistryEntryGetParentEntry(servicePort, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 {
                return parent
            }
        }

        // Strategy 2: Fallback to vendor+model matching
        let vendor = CGDisplayVendorNumber(displayID)
        let model  = CGDisplayModelNumber(displayID)

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }

            guard let cfDict = IODisplayCreateInfoDictionary(
                service,
                IOOptionBits(kIODisplayOnlyPreferredName)
            )?.takeRetainedValue() as? NSDictionary else { continue }

            // Extract vendor and model IDs (may be stored as UInt32 or Int)
            let sVendor: UInt32
            let sModel: UInt32
            if let v = cfDict["DisplayVendorID"] as? UInt32 { sVendor = v } else if let v = cfDict["DisplayVendorID"] as? Int {
                sVendor = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
            } else { continue }

            if let m = cfDict["DisplayProductID"] as? UInt32 { sModel = m } else if let m = cfDict["DisplayProductID"] as? Int {
                sModel = UInt32(bitPattern: Int32(truncatingIfNeeded: m))
            } else { continue }

            guard sVendor == vendor && sModel == model else { continue }

            // Walk up to parent IOFramebuffer
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { continue }
            // Caller must release parent
            return parent
        }
        return nil
    }

    // MARK: - DDC Checksum (Intel path)

    /// Computes DDC/CI checksum: XOR of destination address + all buffer bytes.
    private func ddcChecksum(destAddress: UInt8, bytes: [UInt8]) -> UInt8 {
        var cs: UInt8 = destAddress
        for b in bytes { cs ^= b }
        return cs
    }

    // MARK: - Synchronous DDC I/O (called on a per-display queue)

    /// Synchronous DDC write (VCP Set). Returns true on success.
    /// On ARM64 uses the IOAVService path; on x86_64 uses the IOFramebuffer I2C path.
    private func writeSynchronous(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        let start = DispatchTime.now()
        defer {
            let ms = Self.millisSince(start)
            if ms > Self.slowOpThresholdMs {
                Self.log.notice("slow write \(Self.hex(command), privacy: .public) display \(displayID, privacy: .public): \(Int(ms), privacy: .public) ms")
            }
        }
#if arch(arm64)
        // ARM64 primary path
        if arm64Write(displayID: displayID, command: command, value: value) {
            return true
        }
        return false
#else
        // Intel fallback path
        return intelWriteSynchronous(displayID: displayID, command: command, value: value)
#endif
    }

    /// Consecutive raw read failures per display. Past the threshold the
    /// display's reads are quarantined (fail fast, no I2C traffic) until its
    /// cache is cleared on reconnect. A wedged DDC controller (AOC Q27G3XMN)
    /// streams garbage and degrades further under retry hammering, so backing
    /// off protects both the monitor and the shared DCP I2C engine. Writes
    /// are unaffected; they keep working on wedged controllers.
    private var readFailStreak: [CGDirectDisplayID: Int] = [:]
    private let readStateLock = NSLock()
    private let readQuarantineThreshold = 6
    /// Quarantine expiry per display: after it passes, one fresh probe window
    /// opens (streak resets); persistent failure re-quarantines. Without an
    /// expiry, a transient failure burst on a static setup (no reconnects to
    /// clear the cache) would kill reads for the rest of the session.
    private var readQuarantineUntil: [CGDirectDisplayID: Date] = [:]
    private let readQuarantineInterval: TimeInterval = 600

    /// Synchronous DDC read (VCP Get). Returns (current, max) or nil on failure.
    private func readSynchronous(
        displayID: CGDirectDisplayID,
        command: UInt8
    ) -> (current: UInt16, max: UInt16)? {
        var quarantineExpired = false
        let quarantined = readStateLock.withLock { () -> Bool in
            guard let until = readQuarantineUntil[displayID] else { return false }
            guard Date() >= until else { return true }
            readQuarantineUntil.removeValue(forKey: displayID)
            readFailStreak[displayID] = 0
            quarantineExpired = true
            return false
        }
        guard !quarantined else { return nil }
        if quarantineExpired {
            Self.log.notice("display \(displayID, privacy: .public): read quarantine expired, probing again")
        }

        let start = DispatchTime.now()
#if arch(arm64)
        let result = arm64Read(displayID: displayID, command: command)
#else
        let result = intelReadSynchronous(displayID: displayID, command: command)
#endif
        let ms = Self.millisSince(start)
        if ms > Self.slowOpThresholdMs {
            Self.log.notice("slow read \(Self.hex(command), privacy: .public) display \(displayID, privacy: .public): \(Int(ms), privacy: .public) ms")
        }

        var quarantinedAt: Int?
        readStateLock.withLock {
            if result == nil {
                let streak = readFailStreak[displayID, default: 0] + 1
                readFailStreak[displayID] = streak
                if streak >= readQuarantineThreshold {
                    readQuarantineUntil[displayID] = Date().addingTimeInterval(readQuarantineInterval)
                    quarantinedAt = streak
                }
            } else {
                readFailStreak[displayID] = 0
            }
        }
        if let streak = quarantinedAt {
            Self.log.notice("display \(displayID, privacy: .public): \(streak, privacy: .public) consecutive read failures, reads quarantined for \(Int(self.readQuarantineInterval), privacy: .public) s")
        }
        return result
    }

    // MARK: - Intel Write/Read (renamed from original writeSynchronous/readSynchronous)

    private func intelWriteSynchronous(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        guard let fb = framebufferService(for: displayID) else {
            return false
        }
        defer { IOObjectRelease(fb) }

        // Try all I2C buses (DDC bus is not always bus 0)
        for busIndex: UInt32 in 0..<8 {
            var iface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, busIndex, &iface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iface) }

            var conn: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(iface, IOOptionBits(0), &conn) == KERN_SUCCESS,
                  let conn = conn else { continue }
            defer { IOI2CInterfaceClose(conn, IOOptionBits(0)) }

            // Build DDC/CI Set VCP packet:
            // [0x51, 0x84, 0x03, VCP, val_hi, val_lo, checksum]
            var buf: [UInt8] = [
                0x51,
                0x84,
                0x03,
                command,
                UInt8(value >> 8),
                UInt8(value & 0xFF)
            ]
            buf.append(ddcChecksum(destAddress: 0x6E, bytes: buf))
            let bufCount = buf.count

            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ptr = raw.baseAddress else { return false }
                var req = IOI2CRequest()
                req.commFlags           = 0
                req.sendAddress         = 0x6E
                req.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                req.sendSubAddress      = 0
                req.sendBuffer          = UInt(bitPattern: ptr)
                req.sendBytes           = UInt32(bufCount)
                req.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                req.replyBytes          = 0
                req.minReplyDelay       = 10_000_000 // 10ms
                let kr = IOI2CSendRequest(conn, IOOptionBits(0), &req)
                return kr == KERN_SUCCESS && req.result == KERN_SUCCESS
            }
            if ok {
                return true
            }
        }
        return false
    }

    private func intelReadSynchronous(displayID: CGDirectDisplayID, command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let fb = framebufferService(for: displayID) else { return nil }
        defer { IOObjectRelease(fb) }

        // Try all I2C buses
        for busIndex: UInt32 in 0..<8 {
            var iface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, busIndex, &iface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iface) }

            var conn: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(iface, IOOptionBits(0), &conn) == KERN_SUCCESS,
                  let conn = conn else { continue }
            defer { IOI2CInterfaceClose(conn, IOOptionBits(0)) }

            // Build DDC/CI Get VCP request:
            // [0x51, 0x82, 0x01, VCP, checksum]
            var sendBuf: [UInt8] = [0x51, 0x82, 0x01, command]
            sendBuf.append(ddcChecksum(destAddress: 0x6E, bytes: sendBuf))

            var replyBuf = [UInt8](repeating: 0, count: 12)
            var result: (current: UInt16, max: UInt16)? = nil

            let sendCount  = sendBuf.count
            let replyCount = replyBuf.count

            sendBuf.withUnsafeMutableBytes { sendRaw in
                replyBuf.withUnsafeMutableBytes { replyRaw in
                    guard let sp = sendRaw.baseAddress,
                          let rp = replyRaw.baseAddress else { return }

                    var req = IOI2CRequest()
                    req.commFlags           = 0
                    req.sendAddress         = 0x6E
                    req.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    req.sendSubAddress      = 0
                    req.sendBuffer          = UInt(bitPattern: sp)
                    req.sendBytes           = UInt32(sendCount)
                    req.replyAddress        = 0x6F
                    req.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
                    req.replySubAddress     = 0
                    req.replyBuffer         = UInt(bitPattern: rp)
                    req.replyBytes          = UInt32(replyCount)
                    req.minReplyDelay       = 50_000_000 // 50ms

                    guard IOI2CSendRequest(conn, IOOptionBits(0), &req) == KERN_SUCCESS,
                          req.result == KERN_SUCCESS else { return }

                    // DDC/CI VCP reply layout:
                    // [0x6E, 0x88, 0x02, errCode, VCPcode, type, max_hi, max_lo, cur_hi, cur_lo, chk]
                    let rb = replyRaw.bindMemory(to: UInt8.self)
                    // Validate the reply frame before trusting the payload (see arm64Read):
                    // a monitor can ack the transaction yet return stale/null bytes, whose
                    // bogus "max" would compress the usable brightness range.
                    guard rb[0] == 0x6E, rb[2] == 0x02, rb[3] == 0x00, rb[4] == command else { return }
                    // Header bytes are weak protection against a noise stream;
                    // require the DDC/CI checksum too (see arm64Read).
                    guard self.ddcChecksum(destAddress: 0x50, bytes: Array(rb[0...9])) == rb[10] else { return }
                    let maxVal = (UInt16(rb[6]) << 8) | UInt16(rb[7])
                    let curVal = (UInt16(rb[8]) << 8) | UInt16(rb[9])
                    guard maxVal > 0 else { return }
                    result = (current: curVal, max: maxVal)
                }
            }
            if let r = result { return r }
        }
        return nil
    }

    // MARK: - Cache Cleanup

    /// Removes all cached VCP entries for a display that is no longer connected.
    func clearCache(for displayID: CGDirectDisplayID) {
        cacheLock.lock()
        vcpCache.removeValue(forKey: displayID)
        cacheLock.unlock()
        readStateLock.withLock {
            readFailStreak.removeValue(forKey: displayID)
            readQuarantineUntil.removeValue(forKey: displayID)
        }
        operationQueues.removeQueue(for: displayID)
#if arch(arm64)
        invalidateAVServiceCache(for: displayID)
#endif
    }

    /// Drops every cached display-to-AVService pairing (and read quarantines)
    /// so the next DDC operation re-walks the registry and re-matches by
    /// identity. Called on any display reconfiguration: CGDisplay IDs get
    /// reshuffled across reconnect storms on Apple Silicon, and two IDs that
    /// both survive a storm can end up naming swapped physical panels. A
    /// per-removed-ID cleanup never sees that, and the stale map then writes
    /// one monitor's brightness into the other's channel.
    func invalidateAllChannelMappings() {
        Self.log.notice("display reconfiguration: channel map flushed, pairing re-runs on the next DDC op")
        readStateLock.withLock {
            readFailStreak.removeAll()
            readQuarantineUntil.removeAll()
        }
#if arch(arm64)
        avServiceLock.lock()
        avServiceCache.removeAll()
        noChannelSince.removeAll()
        allExternalAVServices.removeAll()
        lastPairingSummary = ""
        avServiceLock.unlock()
#endif
    }

    /// Keeps every display's DDC queue idle while the caller runs a display transaction:
    /// resolves once every op queued before it has finished, and holds later ops until the
    /// returned closure is called (or 15 s pass, so a lost release cannot wedge DDC for the
    /// session). A display that gets its first op during the hold is held too.
    /// WindowServer's enable of a display waits behind an in-flight I2C transaction on the
    /// DCP, and the machine freezes with it, so PhysicalDisplayToggleService takes this
    /// around every enable and disable.
    func hold() async -> () -> Void {
        let idle = DispatchSemaphore(value: 0)
        let release = operationQueues.hold(timeout: 15) { idle.signal() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                idle.wait()
                continuation.resume()
            }
        }
        return release
    }

    // MARK: - Public Async API (with retry)

    /// Asynchronously write a VCP value, retrying up to 3 times.
    /// Invalidates the cache for the written VCP code on success.
    func writeAsync(
        displayID: CGDirectDisplayID,
        command: UInt8,
        value: UInt16,
        completion: ((Bool) -> Void)? = nil
    ) {
        operationQueues.queue(for: displayID).async {
            for attempt in 0..<3 {
                if self.writeSynchronous(displayID: displayID, command: command, value: value) {
                    // Invalidate cached value so next read reflects the new setting.
                    self.cacheLock.lock()
                    self.vcpCache[displayID]?[command] = nil
                    self.cacheLock.unlock()
                    Self.log.debug("write \(Self.hex(command), privacy: .public)=\(value, privacy: .public) display \(displayID, privacy: .public): ok (attempt \(attempt + 1, privacy: .public))")
                    completion?(true)
                    return
                }
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
            }
            Self.log.error("write \(Self.hex(command), privacy: .public)=\(value, privacy: .public) display \(displayID, privacy: .public): failed all 3 attempts")
            completion?(false)
        }
    }

    /// Asynchronously read a VCP value.
    /// Returns a cached result if available and not expired (5-second TTL).
    func readAsync(
        displayID: CGDirectDisplayID,
        command: UInt8,
        completion: @escaping ((current: UInt16, max: UInt16)?) -> Void
    ) {
        // Fast path: return cached value if still fresh
        cacheLock.lock()
        if let entry = vcpCache[displayID]?[command], !entry.isExpired {
            cacheLock.unlock()
            completion((current: entry.current, max: entry.max))
            return
        }
        cacheLock.unlock()

        operationQueues.queue(for: displayID).async {
            for attempt in 0..<3 {
                if let r = self.readSynchronous(displayID: displayID, command: command) {
                    self.cacheLock.lock()
                    if self.vcpCache[displayID] == nil { self.vcpCache[displayID] = [:] }
                    self.vcpCache[displayID]![command] = VCPCacheEntry(
                        current: r.current, max: r.max, timestamp: Date()
                    )
                    self.cacheLock.unlock()
                    completion(r)
                    return
                }
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
            }
            Self.log.notice("read \(Self.hex(command), privacy: .public) display \(displayID, privacy: .public): no valid reply in 3 attempts")
            completion(nil)
        }
    }

    /// Reads a batch of common VCP codes asynchronously.
    /// Every requested code appears in the result dictionary:
    ///   - `.some(value)` means the code was read successfully (or served from cache)
    ///   - `.none` means the I2C read was attempted but failed
    func readBatchVCPCodes(displayID: CGDirectDisplayID) async -> [UInt8: UInt16?] {
        let codes: [UInt8] = [0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x60, 0x62, 0x87, 0xD6, 0xDC]

        // Check if we have a full fresh cache for all codes
        let cachedResult: [UInt8: UInt16?]? = cacheLock.withLock {
            guard let existingCache = vcpCache[displayID] else { return nil }
            let allCached = codes.allSatisfy { existingCache[$0].map { !$0.isExpired } ?? false }
            guard allCached else { return nil }
            return Dictionary(uniqueKeysWithValues: codes.map { code -> (UInt8, UInt16?) in
                guard let entry = existingCache[code] else { return (code, nil) }
                return (code, entry.current)
            })
        }
        if let cachedResult {
            return cachedResult
        }

        return await withCheckedContinuation { continuation in
            operationQueues.queue(for: displayID).async {
                var result: [UInt8: UInt16?] = [:]
                var cachedCodes = Set<UInt8>()

                // Seed result with any still-valid cached values
                self.cacheLock.lock()
                if let cache = self.vcpCache[displayID] {
                    for code in codes {
                        if let entry = cache[code], !entry.isExpired {
                            result[code] = entry.current
                            cachedCodes.insert(code)
                        }
                    }
                }
                self.cacheLock.unlock()

                // For each code with no fresh cache entry, perform a real I2C read.
                // Every code ends up in result: success → .some(value), failure → .none.
                for code in codes {
                    if cachedCodes.contains(code) { continue }
                    if let r = self.readSynchronous(displayID: displayID, command: code) {
                        result[code] = r.current
                        self.cacheLock.lock()
                        if self.vcpCache[displayID] == nil { self.vcpCache[displayID] = [:] }
                        self.vcpCache[displayID]![code] = VCPCacheEntry(
                            current: r.current, max: r.max, timestamp: Date()
                        )
                        self.cacheLock.unlock()
                        // No extra delay here, arm64Read already waits 40ms per DDC/CI spec
                    } else {
                        result[code] = nil
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }
}
