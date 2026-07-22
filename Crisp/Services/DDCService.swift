import Foundation
import Combine
import CoreGraphics
import IOKit
import IOKit.i2c
import IOKit.graphics

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

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
    static let powerVCP: UInt8      = 0xD6

    private let ddcQueue = DispatchQueue(label: "com.crisp.ddc", qos: .userInitiated)

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
    private let avServiceLock = NSLock()
    /// Ordered list of all working external AVServices found during last enumeration.
    private var allExternalAVServices: [IOAVServiceRef] = []
#endif

    private init() {}

    // MARK: - ARM64 IOAVService Path

#if arch(arm64)
    // MARK: - ARM64 IORegistry-based AVService matching

    /// Mapping warning exposed to UI when more than one external display is connected
    /// and we fall back to index-based AVService assignment.
    @Published var mappingWarning: String? = nil

    /// Attempts to match an IOAVService (DCPAVServiceProxy) to a CGDirectDisplayID by
    /// comparing IORegistry properties against CoreGraphics display attributes.
    ///
    /// Matching strategy (in order of reliability):
    ///   1. Walk up the IORegistry parent chain from the DCPAVServiceProxy node to find a node
    ///      that has both "DisplayVendorID" and "DisplayProductID", then compare against
    ///      CGDisplayVendorNumber / CGDisplayModelNumber for each external display.
    ///   2. If no vendor/product match is found, fall back to sorted-index assignment and
    ///      emit a console warning (and set mappingWarning if >1 external display).
    ///
    /// Returns a dictionary mapping each matched external CGDirectDisplayID to its AVService.
    private func buildAVServiceMap(
        workingServices: [(service: IOAVServiceRef, ioEntry: io_service_t)]
    ) -> [CGDirectDisplayID: IOAVServiceRef] {
        // Collect all external display IDs
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        let externalIDs = (0..<Int(displayCount))
            .map { displayIDs[$0] }
            .filter { CGDisplayIsBuiltin($0) == 0 }

        guard !externalIDs.isEmpty else { return [:] }

        var result: [CGDirectDisplayID: IOAVServiceRef] = [:]
        var unmatchedServices: [(service: IOAVServiceRef, ioEntry: io_service_t)] = []

        // Strategy 1: IORegistry property matching
        for entry in workingServices {
            guard let matched = matchAVServiceToDisplay(
                ioEntry: entry.ioEntry,
                candidates: externalIDs,
                alreadyMapped: Set(result.keys)
            ) else {
                unmatchedServices.append(entry)
                continue
            }
            result[matched] = entry.service
            #if DEBUG
            print("[DDCService] ARM64: IORegistry matched AVService to display \(matched) (vendor/product)")
            #endif
        }

        // Strategy 2: Index fallback for any remaining unmatched services/displays
        let unmappedIDs = externalIDs.filter { result[$0] == nil }.sorted()
        if !unmatchedServices.isEmpty && !unmappedIDs.isEmpty {
            if unmappedIDs.count > 1 {
                let warning = "Multiple external displays: DDC may target wrong monitor (IORegistry matching failed)"
                #if DEBUG
                print("[DDCService] WARNING: \(warning)")
                #endif
                DispatchQueue.main.async { self.mappingWarning = warning }
            } else {
                DispatchQueue.main.async { self.mappingWarning = nil }
            }
            for (idx, extID) in unmappedIDs.enumerated() {
                if idx < unmatchedServices.count {
                    result[extID] = unmatchedServices[idx].service
                    #if DEBUG
                    print("[DDCService] ARM64: index fallback mapped AVService[\(idx)] to display \(extID)")
                    #endif
                }
            }
        } else {
            DispatchQueue.main.async { self.mappingWarning = nil }
        }

        return result
    }

    /// Walks up the IORegistry parent chain from `ioEntry` looking for a node
    /// that has both "DisplayVendorID" and "DisplayProductID" properties.
    /// Returns the CGDirectDisplayID from `candidates` whose vendor+model matches,
    /// excluding any IDs already in `alreadyMapped`.
    private func matchAVServiceToDisplay(
        ioEntry: io_service_t,
        candidates: [CGDirectDisplayID],
        alreadyMapped: Set<CGDirectDisplayID>
    ) -> CGDirectDisplayID? {
        // Build the ancestor chain (up to 8 levels) including the entry itself
        var chain: [io_service_t] = []
        var current = ioEntry
        IOObjectRetain(current)
        chain.append(current)

        for _ in 0..<7 {
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != IO_OBJECT_NULL else { break }
            chain.append(parent)
            current = parent
        }
        defer { chain.forEach { IOObjectRelease($0) } }

        for node in chain {
            guard let cfProps = ioRegistryEntryProperties(node) else { continue }
            let props = cfProps.takeRetainedValue() as? [String: Any] ?? [:]

            // Extract vendor and product IDs from this node
            let nodeVendor: UInt32?
            let nodeProduct: UInt32?

            if let v = props["DisplayVendorID"] as? UInt32 { nodeVendor = v }
            else if let v = props["DisplayVendorID"] as? Int { nodeVendor = UInt32(bitPattern: Int32(truncatingIfNeeded: v)) }
            else { nodeVendor = nil }

            if let p = props["DisplayProductID"] as? UInt32 { nodeProduct = p }
            else if let p = props["DisplayProductID"] as? Int { nodeProduct = UInt32(bitPattern: Int32(truncatingIfNeeded: p)) }
            else { nodeProduct = nil }

            guard let vendor = nodeVendor, let product = nodeProduct else { continue }

            // Find a candidate display whose vendor+model matches
            for dispID in candidates {
                guard !alreadyMapped.contains(dispID) else { continue }
                if CGDisplayVendorNumber(dispID) == vendor && CGDisplayModelNumber(dispID) == product {
                    return dispID
                }
            }
        }

        return nil
    }

    /// Wraps IORegistryEntryCreateCFProperties to return an optional Unmanaged<CFDictionary>.
    private func ioRegistryEntryProperties(_ entry: io_service_t) -> Unmanaged<CFDictionary>? {
        var props: Unmanaged<CFMutableDictionary>? = nil
        let kr = IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let p = props else { return nil }
        // CFMutableDictionary is toll-free bridged to CFDictionary
        return unsafeBitCast(p, to: Unmanaged<CFDictionary>.self)
    }

    /// Finds the IOAVService for the given display. Caches the result per display.
    /// Returns nil if no working AVService is found (built-in displays, or displays
    /// that don't support DDC over the Apple Silicon AV path).
    ///
    /// Matching strategy: IORegistry vendor/product property matching first,
    /// falling back to sorted-index assignment if properties are unavailable.
    private func findAVService(for displayID: CGDirectDisplayID) -> IOAVServiceRef? {
        // Fast path: return cached service if present
        avServiceLock.lock()
        if let cached = avServiceCache[displayID] {
            avServiceLock.unlock()
            return cached
        }
        avServiceLock.unlock()

        // Slow path: enumerate all DCPAVServiceProxy nodes in the IOKit registry.
        // Double-checked locking: another thread may have filled the cache between
        // the fast-path unlock and now, so we re-check inside the lock at the end
        // before writing results.
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        // Collect (AVService, io_service_t) pairs for IORegistry property matching.
        // We retain each io_service_t so we can walk its parent chain after the iterator moves on.
        var workingPairs: [(service: IOAVServiceRef, ioEntry: io_service_t)] = []

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            // Only consider external displays
            if let locationProp = IORegistryEntryCreateCFProperty(
                service, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String {
                guard locationProp == "External" else {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                    continue
                }
            }
            // Note: some drivers omit the "Location" key entirely; still attempt those.

            guard let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service) else {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
                continue
            }

            // Verify the service responds to I2C reads (confirms it's a usable DDC path)
            var testBuf = [UInt8](repeating: 0, count: 32)
            let ret = IOAVServiceReadI2C(avService, 0x37, 0x51, &testBuf, 32)
            if ret == kIOReturnSuccess {
                // Retain io_service_t so we can walk its parent chain in buildAVServiceMap
                IOObjectRetain(service)
                workingPairs.append((service: avService, ioEntry: service))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        guard !workingPairs.isEmpty else {
            #if DEBUG
            print("[DDCService] ARM64: no IOAVService found for display \(displayID)")
            #endif
            return nil
        }

        // Build the display→AVService map using IORegistry matching
        let serviceMap = buildAVServiceMap(workingServices: workingPairs)

        // Release the retained io_service_t entries now that mapping is done
        for pair in workingPairs {
            IOObjectRelease(pair.ioEntry)
        }

        // Re-check cache (double-checked locking) in case another thread enumerated
        // and populated the cache while we were enumerating without the lock held.
        avServiceLock.lock()
        if let cached = avServiceCache[displayID] {
            avServiceLock.unlock()
            return cached
        }
        allExternalAVServices = workingPairs.map { $0.service }
        for (extID, avService) in serviceMap {
            avServiceCache[extID] = avService
        }
        let result = avServiceCache[displayID]
        avServiceLock.unlock()

        #if DEBUG
        if result != nil {
            print("[DDCService] ARM64: found IOAVService for display \(displayID)")
        } else {
            print("[DDCService] ARM64: no IOAVService found for display \(displayID)")
        }
        #endif
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
        guard let avService = findAVService(for: displayID) else { return false }

        let valueHigh = UInt8((value >> 8) & 0xFF)
        let valueLow  = UInt8(value & 0xFF)
        // Checksum seed: 0x50 = 0x6E (DDC destination) XOR 0x51 (sub-address used by IOAVServiceWriteI2C)
        // then XOR with each byte in the payload.
        var checksum  = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x84, 0x03, command, valueHigh, valueLow]
        for b in payload { checksum ^= b }

        var buf: [UInt8] = payload + [checksum]
        let ret = IOAVServiceWriteI2C(avService, 0x37, 0x51, &buf, UInt32(buf.count))
        #if DEBUG
        if ret == kIOReturnSuccess {
            print("[DDCService] ARM64 write VCP 0x\(String(command, radix: 16)) = \(value) OK")
        } else {
            print("[DDCService] ARM64 write VCP 0x\(String(command, radix: 16)) failed: \(ret)")
        }
        #endif
        return ret == kIOReturnSuccess
    }

    /// ARM64 DDC read: send a Get VCP request then read the response via IOAVService.
    /// Request layout: [0x82, 0x01, vcpCode, checksum]
    /// Response bytes 4-7 carry: [maxHigh, maxLow, curHigh, curLow]
    private func arm64Read(displayID: CGDirectDisplayID, command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let avService = findAVService(for: displayID) else { return nil }

        // Build and send the VCP Get Request packet
        var requestChecksum = UInt8(0x6E ^ 0x51)
        let requestPayload: [UInt8] = [0x82, 0x01, command]
        for b in requestPayload { requestChecksum ^= b }
        var requestBuf: [UInt8] = requestPayload + [requestChecksum]

        let writeRet = IOAVServiceWriteI2C(avService, 0x37, 0x51, &requestBuf, UInt32(requestBuf.count))
        guard writeRet == kIOReturnSuccess else {
            #if DEBUG
            print("[DDCService] ARM64 read request failed for VCP 0x\(String(command, radix: 16)): \(writeRet)")
            #endif
            return nil
        }

        // Wait for the display to prepare its DDC/CI reply (~40ms per spec)
        Thread.sleep(forTimeInterval: 0.04)

        // Read the VCP reply
        var replyBuf = [UInt8](repeating: 0, count: 12)
        let readRet = IOAVServiceReadI2C(avService, 0x37, 0x51, &replyBuf, UInt32(replyBuf.count))
        guard readRet == kIOReturnSuccess else {
            #if DEBUG
            print("[DDCService] ARM64 read reply failed for VCP 0x\(String(command, radix: 16)): \(readRet)")
            #endif
            return nil
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

        let maxVal = (UInt16(replyBuf[6]) << 8) | UInt16(replyBuf[7])
        let curVal = (UInt16(replyBuf[8]) << 8) | UInt16(replyBuf[9])
        #if DEBUG
        print("[DDCService] ARM64 read VCP 0x\(String(command, radix: 16)): cur=\(curVal) max=\(maxVal)")
        #endif
        return (current: curVal, max: maxVal)
    }
#endif

    // MARK: - Intel (x86_64) IOFramebuffer Path

    /// Finds the IOFramebuffer service for a given external display.
    /// Returns a retained io_service_t — caller must IOObjectRelease.
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
            if let v = cfDict["DisplayVendorID"] as? UInt32 { sVendor = v }
            else if let v = cfDict["DisplayVendorID"] as? Int {
                sVendor = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
            } else { continue }

            if let m = cfDict["DisplayProductID"] as? UInt32 { sModel = m }
            else if let m = cfDict["DisplayProductID"] as? Int {
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

    // MARK: - Synchronous DDC I/O (called on ddcQueue)

    /// Synchronous DDC write (VCP Set). Returns true on success.
    /// On ARM64 uses the IOAVService path; on x86_64 uses the IOFramebuffer I2C path.
    private func writeSynchronous(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
#if arch(arm64)
        // ARM64 primary path
        if arm64Write(displayID: displayID, command: command, value: value) {
            return true
        }
        #if DEBUG
        print("[DDCService] writeSynchronous ARM64: failed for display \(displayID) VCP 0x\(String(command, radix: 16))")
        #endif
        return false
#else
        // Intel fallback path
        return intelWriteSynchronous(displayID: displayID, command: command, value: value)
#endif
    }

    /// Synchronous DDC read (VCP Get). Returns (current, max) or nil on failure.
    private func readSynchronous(displayID: CGDirectDisplayID, command: UInt8) -> (current: UInt16, max: UInt16)? {
#if arch(arm64)
        return arm64Read(displayID: displayID, command: command)
#else
        return intelReadSynchronous(displayID: displayID, command: command)
#endif
    }

    // MARK: - Intel Write/Read (renamed from original writeSynchronous/readSynchronous)

    private func intelWriteSynchronous(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        guard let fb = framebufferService(for: displayID) else {
            #if DEBUG
            print("[DDCService] intelWrite: no framebuffer for display \(displayID)")
            #endif
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
                #if DEBUG
                print("[DDCService] Intel write VCP 0x\(String(command, radix:16)) = \(value) on bus \(busIndex) OK")
                #endif
                return true
            }
        }
        #if DEBUG
        print("[DDCService] intelWrite: all buses failed for display \(displayID) VCP 0x\(String(command, radix:16))")
        #endif
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
                    let maxVal = (UInt16(rb[6]) << 8) | UInt16(rb[7])
                    let curVal = (UInt16(rb[8]) << 8) | UInt16(rb[9])
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
#if arch(arm64)
        invalidateAVServiceCache(for: displayID)
#endif
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
        ddcQueue.async {
            for attempt in 0..<3 {
                if self.writeSynchronous(displayID: displayID, command: command, value: value) {
                    // Invalidate cached value so next read reflects the new setting.
                    self.cacheLock.lock()
                    self.vcpCache[displayID]?[command] = nil
                    self.cacheLock.unlock()
                    completion?(true)
                    return
                }
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
            }
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

        ddcQueue.async {
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
            ddcQueue.async {
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
                        // No extra delay here — arm64Read already waits 40ms per DDC/CI spec
                    } else {
                        result[code] = nil
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }
}
