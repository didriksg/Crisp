// Read-only inspector and manual opt-in proof-of-concept tool for native macOS
// underscan via MonitorPanel.framework (MPDisplayMgr / MPDisplay).
//
// Default mode (--inspect) is strictly read-only and never mutates display state.
// Write mode (--set) requires explicit arguments and is intended only for manual
// hardware verification on the user's desk.
//
// Compile:
//   swiftc -O -swift-version 6 scripts/underscan-probe.swift -o build/underscan-probe
// Inspect (read-only):
//   ./build/underscan-probe --inspect
// Manual hardware test (mutates display, optional auto-restore):
//   ./build/underscan-probe --set <displayID> <percent 75..100> [--force] [--restore-after 5]

import ColorSync
import CoreGraphics
import Foundation
import ObjectiveC.runtime

private enum ProbeError: Error, CustomStringConvertible {
    case frameworkUnavailable(String)
    case classMissing(String)
    case selectorMissing(String)
    case unexpectedSignature(String, expected: String, actual: String)
    case displayNotFound(CGDirectDisplayID)

    var description: String {
        switch self {
        case .frameworkUnavailable(let path): return "Failed to dlopen \(path)"
        case .classMissing(let name): return "Missing ObjC class \(name)"
        case .selectorMissing(let name): return "Missing selector \(name)"
        case .unexpectedSignature(let sel, let expected, let actual):
            return "Unexpected signature for \(sel): expected \(expected), got \(actual)"
        case .displayNotFound(let id): return "Display \(id) not found in MPDisplayMgr"
        }
    }
}

private struct VerifiedMethod {
    let selector: Selector
    let imp: IMP
}

private func verifyMethod(
    on cls: AnyClass,
    selectorName: String,
    expectedReturnPrefixes: [String],
    expectedArgPrefixes: [String]
) throws -> VerifiedMethod {
    let sel = NSSelectorFromString(selectorName)
    guard let method = class_getInstanceMethod(cls, sel) else {
        throw ProbeError.selectorMissing(selectorName)
    }

    let expectedArgCount = UInt32(2 + expectedArgPrefixes.count)
    let actualArgCount = method_getNumberOfArguments(method)
    guard actualArgCount == expectedArgCount else {
        throw ProbeError.unexpectedSignature(
            selectorName,
            expected: "\(expectedArgCount) args",
            actual: "\(actualArgCount) args"
        )
    }

    let retPtr = method_copyReturnType(method)
    let retType = String(cString: retPtr)
    free(retPtr)
    guard expectedReturnPrefixes.contains(where: { retType.hasPrefix($0) }) else {
        throw ProbeError.unexpectedSignature(
            selectorName,
            expected: "return in \(expectedReturnPrefixes)",
            actual: retType
        )
    }

    for (idx, prefix) in expectedArgPrefixes.enumerated() {
        guard let argPtr = method_copyArgumentType(method, UInt32(idx + 2)) else {
            throw ProbeError.unexpectedSignature(selectorName, expected: prefix, actual: "<nil>")
        }
        let argType = String(cString: argPtr)
        free(argPtr)
        guard argType.hasPrefix(prefix) else {
            throw ProbeError.unexpectedSignature(
                selectorName,
                expected: "arg[\(idx)]=\(prefix)",
                actual: argType
            )
        }
    }

    return VerifiedMethod(selector: sel, imp: method_getImplementation(method))
}

private final class MonitorPanelBridge {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel"

    private let mgrClass: NSObject.Type
    private let displayClass: AnyClass
    private let displayWithIDMethod: VerifiedMethod
    private let supportsUnderscanMethod: VerifiedMethod
    private let minUnderscanMethod: VerifiedMethod
    private let maxUnderscanMethod: VerifiedMethod
    private let underscanGetterMethod: VerifiedMethod
    private let setUnderscanMethod: VerifiedMethod

    init() throws {
        guard dlopen(Self.frameworkPath, RTLD_LAZY) != nil else {
            throw ProbeError.frameworkUnavailable(Self.frameworkPath)
        }
        guard let mgrCls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else {
            throw ProbeError.classMissing("MPDisplayMgr")
        }
        guard let dispCls: AnyClass = NSClassFromString("MPDisplay") else {
            throw ProbeError.classMissing("MPDisplay")
        }

        self.mgrClass = mgrCls
        self.displayClass = dispCls
        self.displayWithIDMethod = try verifyMethod(
            on: mgrCls,
            selectorName: "displayWithID:",
            expectedReturnPrefixes: ["@"],
            expectedArgPrefixes: ["i"]
        )
        // Bool is encoded as "B" (arm64 / modern ObjC) or "c" (signed char BOOL on some x86_64 builds).
        self.supportsUnderscanMethod = try verifyMethod(
            on: dispCls,
            selectorName: "supportsUnderscan",
            expectedReturnPrefixes: ["B", "c"],
            expectedArgPrefixes: []
        )
        self.minUnderscanMethod = try verifyMethod(
            on: dispCls,
            selectorName: "minUnderscan",
            expectedReturnPrefixes: ["i"],
            expectedArgPrefixes: []
        )
        self.maxUnderscanMethod = try verifyMethod(
            on: dispCls,
            selectorName: "maxUnderscan",
            expectedReturnPrefixes: ["i"],
            expectedArgPrefixes: []
        )
        self.underscanGetterMethod = try verifyMethod(
            on: dispCls,
            selectorName: "underscan",
            expectedReturnPrefixes: ["i"],
            expectedArgPrefixes: []
        )
        self.setUnderscanMethod = try verifyMethod(
            on: dispCls,
            selectorName: "setUnderscan:",
            expectedReturnPrefixes: ["v"],
            expectedArgPrefixes: ["i"]
        )
    }

    private func mpDisplay(for displayID: CGDirectDisplayID) throws -> AnyObject {
        let mgr = mgrClass.init()
        typealias Fn = @convention(c) (AnyObject, Selector, Int32) -> AnyObject?
        let fn = unsafeBitCast(displayWithIDMethod.imp, to: Fn.self)
        guard let display = fn(mgr, displayWithIDMethod.selector, Int32(bitPattern: displayID)) else {
            throw ProbeError.displayNotFound(displayID)
        }
        return display
    }

    func supportsUnderscan(displayID: CGDirectDisplayID) throws -> Bool {
        let display = try mpDisplay(for: displayID)
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let fn = unsafeBitCast(supportsUnderscanMethod.imp, to: Fn.self)
        return fn(display, supportsUnderscanMethod.selector)
    }

    /// Only call when supportsUnderscan == true; calling getters on unsupported displays on
    /// Apple Silicon can crash or return invalid state.
    func readRangeAndCurrent(displayID: CGDirectDisplayID) throws -> (minRaw: Int32, maxRaw: Int32, currentRaw: Int32?) {
        let display = try mpDisplay(for: displayID)
        typealias IntGetter = @convention(c) (AnyObject, Selector) -> Int32
        let getMin = unsafeBitCast(minUnderscanMethod.imp, to: IntGetter.self)
        let getMax = unsafeBitCast(maxUnderscanMethod.imp, to: IntGetter.self)
        let lo = getMin(display, minUnderscanMethod.selector)
        let hi = getMax(display, maxUnderscanMethod.selector)
        guard lo >= 5000, hi <= 10000, lo < hi else {
            return (lo, hi, nil)
        }
        let getCur = unsafeBitCast(underscanGetterMethod.imp, to: IntGetter.self)
        let cur = getCur(display, underscanGetterMethod.selector)
        return (lo, hi, (lo...hi).contains(cur) ? cur : nil)
    }

    func setUnderscan(displayID: CGDirectDisplayID, rawValue: Int32) throws {
        let display = try mpDisplay(for: displayID)
        typealias Setter = @convention(c) (AnyObject, Selector, Int32) -> Void
        let fn = unsafeBitCast(setUnderscanMethod.imp, to: Setter.self)
        fn(display, setUnderscanMethod.selector, rawValue)
    }
}

private func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

private func displayUUID(_ id: CGDirectDisplayID) -> String {
    guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id),
          let str = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) else {
        return "<unavailable>"
    }
    return str as String
}

private func printInspection(bridge: MonitorPanelBridge) {
    #if arch(arm64)
    let arch = "arm64 (Apple Silicon)"
    #elseif arch(x86_64)
    let arch = "x86_64 (Intel)"
    #else
    let arch = "unknown"
    #endif
    print("Host: \(arch), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("MonitorPanel.framework signatures: VERIFIED")

    let ids = onlineDisplays()
    print("Online displays: \(ids.count)")
    for id in ids {
        let builtin = CGDisplayIsBuiltin(id) != 0
        let mode = CGDisplayCopyDisplayMode(id)
        let modeDesc: String
        if let m = mode {
            let hidpi = m.pixelWidth > m.width ? "HiDPI" : "1x"
            modeDesc = "\(m.width)x\(m.height) (backing \(m.pixelWidth)x\(m.pixelHeight), \(hidpi), \(String(format: "%.1f", m.refreshRate))Hz)"
        } else {
            modeDesc = "<no mode>"
        }
        print("  Display \(id):")
        print("    UUID: \(displayUUID(id))")
        print("    Vendor/Model/Serial: 0x\(String(CGDisplayVendorNumber(id), radix: 16)) / 0x\(String(CGDisplayModelNumber(id), radix: 16)) / \(CGDisplaySerialNumber(id))")
        print("    Built-in: \(builtin), Mode: \(modeDesc)")
        do {
            let supported = try bridge.supportsUnderscan(displayID: id)
            print("    MPDisplay.supportsUnderscan: \(supported)")
            if supported {
                let info = try bridge.readRangeAndCurrent(displayID: id)
                print("    Verified range: \(info.minRaw)...\(info.maxRaw) (\(info.minRaw / 100)%...\(info.maxRaw / 100)%)")
                if let cur = info.currentRaw {
                    print("    Hardware-confirmed underscan: \(cur) (\(String(format: "%.2f", Double(cur) / 100.0))%)")
                } else {
                    print("    Hardware-confirmed underscan: unavailable")
                }
            } else {
                print("    Readback skipped (supportsUnderscan == false; getter unsafe on Apple Silicon)")
            }
        } catch {
            print("    MonitorPanel query error: \(error)")
        }
    }
}

private func runMain() {
    do {
        let bridge = try MonitorPanelBridge()
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args.first == "--inspect" {
            printInspection(bridge: bridge)
            return
        }

        if args.first == "--set", args.count >= 3,
           let id = CGDirectDisplayID(args[1]),
           let percent = Int(args[2]) {
            guard (75...100).contains(percent) else {
                fputs("error: percent must be between 75 and 100\n", stderr)
                exit(2)
            }
            let force = args.contains("--force")
            var restoreAfter: Double? = nil
            if let idx = args.firstIndex(of: "--restore-after"), idx + 1 < args.count {
                restoreAfter = Double(args[idx + 1])
            }
            let supported = try bridge.supportsUnderscan(displayID: id)
            guard supported || force else {
                fputs("error: display \(id) does not report native underscan support (pass --force to test experimentally)\n", stderr)
                exit(1)
            }
            let previousRaw: Int32? = supported ? (try bridge.readRangeAndCurrent(displayID: id).currentRaw) : nil
            let targetRaw = Int32(percent * 100)
            print("Submitting setUnderscan(\(targetRaw)) [\(percent)%] to display \(id) (nativeSupported=\(supported), force=\(force))...")
            try bridge.setUnderscan(displayID: id, rawValue: targetRaw)
            if supported {
                let after = try bridge.readRangeAndCurrent(displayID: id)
                print("Hardware readback after set: \(String(describing: after.currentRaw))")
            } else {
                print("Submitted without readback (experimental force path).")
            }
            if let waitSec = restoreAfter {
                print("Waiting \(waitSec)s before restoring...")
                Thread.sleep(forTimeInterval: waitSec)
                let restoreRaw = previousRaw ?? 10000
                print("Restoring setUnderscan(\(restoreRaw))...")
                try bridge.setUnderscan(displayID: id, rawValue: restoreRaw)
            }
            return
        }

        print("Usage:")
        print("  underscan-probe [--inspect]")
        print("  underscan-probe --set <displayID> <percent 75..100> [--force] [--restore-after <seconds>]")
        exit(2)
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
}

runMain()
