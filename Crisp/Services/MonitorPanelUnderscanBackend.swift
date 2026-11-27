import CoreGraphics
import Foundation
import ObjectiveC.runtime
import os

/// Compatibility layer isolating all private `MonitorPanel.framework` (`MPDisplayMgr` /
/// `MPDisplay`) loading, runtime Objective-C signature validation, and Apple Silicon
/// safety guards behind `UnderscanBackend`.
///
/// Safety guarantees:
/// - Loaded dynamically via `dlopen` at runtime; missing framework or symbols never crash.
/// - Every Objective-C selector's argument count, argument types, and return type are
///   verified via `method_getNumberOfArguments` / `method_copyReturnType` /
///   `method_copyArgumentType` before invoking its `IMP`.
/// - On displays where `supportsUnderscan` is `false` (including experimental force-enable
///   on Apple Silicon), `underscan`, `minUnderscan`, and `maxUnderscan` getters are NEVER
///   invoked because undocumented getter calls on unsupported Apple Silicon pipelines can
///   crash or return invalid state.
/// - All MonitorPanel calls run on a dedicated private serial queue, keeping main-thread
///   rendering and SwiftUI layout free of IPC stalls or run-loop reentrancy.
final class MonitorPanelUnderscanBackend: UnderscanBackend, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.crisp.app", category: "underscan")
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel"

    private struct VerifiedMethod {
        let selector: Selector
        let imp: IMP
    }

    private struct ResolvedSymbols {
        let mgrClass: NSObject.Type
        let displayWithID: VerifiedMethod
        let supportsUnderscan: VerifiedMethod
        let minUnderscan: VerifiedMethod
        let maxUnderscan: VerifiedMethod
        let underscanGetter: VerifiedMethod
        let setUnderscan: VerifiedMethod
    }

    private enum ResolutionState {
        case ready(ResolvedSymbols)
        case frameworkUnavailable(String)
        case symbolMissing(String)
        case invalidSignature(String)
    }

    let hostArchitecture: HostArchitecture = .current
    private let osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    private let queue = DispatchQueue(label: "com.crisp.underscan.monitorpanel", qos: .userInitiated)
    private let resolution: ResolutionState

    init() {
        self.resolution = Self.resolveMonitorPanel()
    }

    // MARK: - UnderscanBackend

    func probeCapability(for display: DisplayUnderscanDescriptor) -> UnderscanCapability {
        if display.isBuiltin {
            return makeCapability(.builtInRestricted, readbackAvailable: false, confirmedRaw: nil)
        }
        if display.isVirtual {
            return makeCapability(.virtualDisplayUnsupported, readbackAvailable: false, confirmedRaw: nil)
        }
        guard CGDisplayIsOnline(display.displayID) != 0 else {
            return makeCapability(.displayNotFound, readbackAvailable: false, confirmedRaw: nil)
        }

        return queue.sync {
            switch resolution {
            case .frameworkUnavailable(let name):
                return makeCapability(.frameworkUnavailable(framework: name), readbackAvailable: false, confirmedRaw: nil)
            case .symbolMissing(let symbol):
                return makeCapability(.symbolMissing(symbol: symbol), readbackAvailable: false, confirmedRaw: nil)
            case .invalidSignature(let symbol):
                return makeCapability(.invalidSignature(symbol: symbol), readbackAvailable: false, confirmedRaw: nil)
            case .ready(let symbols):
                return probeWithSymbols(symbols, for: display)
            }
        }
    }

    func applyUnderscan(
        rawValue: Int32,
        to display: DisplayUnderscanDescriptor,
        forceExperimental: Bool
    ) -> Result<UnderscanApplyOutcome, UnderscanError> {
        if display.isBuiltin {
            return .failure(.builtInDisplayBlocked)
        }
        if display.isVirtual {
            return .failure(.virtualDisplayUnsupported)
        }
        guard CGDisplayIsOnline(display.displayID) != 0 else {
            return .failure(.displayNotFound(display.displayID))
        }

        return queue.sync {
            switch resolution {
            case .frameworkUnavailable(let name):
                return .failure(.frameworkUnavailable(name))
            case .symbolMissing(let symbol):
                return .failure(.symbolMissing(symbol))
            case .invalidSignature(let symbol):
                return .failure(.invalidSignature(symbol))
            case .ready(let symbols):
                return applyWithSymbols(
                    symbols,
                    rawValue: rawValue,
                    to: display,
                    forceExperimental: forceExperimental
                )
            }
        }
    }

    func readHardwareUnderscan(for display: DisplayUnderscanDescriptor) -> Int32? {
        guard !display.isBuiltin, !display.isVirtual, CGDisplayIsOnline(display.displayID) != 0 else {
            return nil
        }
        return queue.sync {
            guard case .ready(let symbols) = resolution,
                  let mpDisplay = lookupMPDisplay(symbols: symbols, displayID: display.displayID),
                  callBoolGetter(symbols.supportsUnderscan, on: mpDisplay) else {
                return nil
            }
            let minRaw = callIntGetter(symbols.minUnderscan, on: mpDisplay)
            let maxRaw = callIntGetter(symbols.maxUnderscan, on: mpDisplay)
            guard let range = UnderscanValue.validatedHardwareRange(minRaw: minRaw, maxRaw: maxRaw) else {
                return nil
            }
            let value = callIntGetter(symbols.underscanGetter, on: mpDisplay)
            return range.contains(value) ? value : nil
        }
    }

    // MARK: - Private Runtime Bridge

    private func probeWithSymbols(
        _ symbols: ResolvedSymbols,
        for display: DisplayUnderscanDescriptor
    ) -> UnderscanCapability {
        guard let mpDisplay = lookupMPDisplay(symbols: symbols, displayID: display.displayID) else {
            return makeCapability(.displayNotFound, readbackAvailable: false, confirmedRaw: nil)
        }

        let supported = callBoolGetter(symbols.supportsUnderscan, on: mpDisplay)
        guard supported else {
            // CRITICAL Apple Silicon safety rule: never invoke minUnderscan/maxUnderscan/underscan
            // getters when macOS reports supportsUnderscan == false.
            let reason = String(
                localized: "macOS does not expose native underscan for this display or connection."
            )
            return makeCapability(.unsupportedHardware(reason: reason), readbackAvailable: false, confirmedRaw: nil)
        }

        let minRaw = callIntGetter(symbols.minUnderscan, on: mpDisplay)
        let maxRaw = callIntGetter(symbols.maxUnderscan, on: mpDisplay)
        guard let validRange = UnderscanValue.validatedHardwareRange(minRaw: minRaw, maxRaw: maxRaw) else {
            Self.log.notice(
                "display \(display.displayID, privacy: .public): MonitorPanel reported invalid underscan range \(minRaw, privacy: .public)...\(maxRaw, privacy: .public)"
            )
            let reason = String(
                localized: "Display reported an unsupported underscan range."
            )
            return makeCapability(.unsupportedHardware(reason: reason), readbackAvailable: false, confirmedRaw: nil)
        }

        // Safe readback: only reached when supportsUnderscan == true AND range passed sanity validation.
        let rawCurrent = callIntGetter(symbols.underscanGetter, on: mpDisplay)
        let confirmedRaw = validRange.contains(rawCurrent) ? rawCurrent : nil
        let canReadback = confirmedRaw != nil
        return makeCapability(
            .nativeSupported(minRaw: validRange.lowerBound, maxRaw: validRange.upperBound, canReadback: canReadback),
            readbackAvailable: canReadback,
            confirmedRaw: confirmedRaw
        )
    }

    private func applyWithSymbols(
        _ symbols: ResolvedSymbols,
        rawValue: Int32,
        to display: DisplayUnderscanDescriptor,
        forceExperimental: Bool
    ) -> Result<UnderscanApplyOutcome, UnderscanError> {
        guard let mpDisplay = lookupMPDisplay(symbols: symbols, displayID: display.displayID) else {
            return .failure(.displayNotFound(display.displayID))
        }

        let nativeSupported = callBoolGetter(symbols.supportsUnderscan, on: mpDisplay)
        if !nativeSupported && !forceExperimental {
            return .failure(.unsupportedDisplay(
                String(localized: "macOS does not expose native underscan for this display or connection.")
            ))
        }

        let allowedRange: ClosedRange<Int32>
        if nativeSupported {
            let minRaw = callIntGetter(symbols.minUnderscan, on: mpDisplay)
            let maxRaw = callIntGetter(symbols.maxUnderscan, on: mpDisplay)
            allowedRange = UnderscanValue.validatedHardwareRange(minRaw: minRaw, maxRaw: maxRaw)
                ?? UnderscanValue.defaultRawRange
        } else {
            allowedRange = UnderscanValue.defaultRawRange
        }

        guard allowedRange.contains(rawValue) else {
            return .failure(.invalidValue(
                UnderscanValue.percentage(fromRaw: rawValue),
                UnderscanValue.percentageRange(forRawRange: allowedRange)
            ))
        }

        callIntSetter(symbols.setUnderscan, on: mpDisplay, value: rawValue)
        Self.log.notice(
            "display \(display.displayID, privacy: .public): submitted native underscan \(rawValue, privacy: .public) (nativeSupported=\(nativeSupported, privacy: .public), force=\(forceExperimental, privacy: .public))"
        )

        // Never invoke underscan getter on the experimental/unsupported path (Apple Silicon safety).
        var confirmedRaw: Int32? = nil
        if nativeSupported {
            let readBack = callIntGetter(symbols.underscanGetter, on: mpDisplay)
            if allowedRange.contains(readBack) {
                confirmedRaw = readBack
            }
        }

        return .success(UnderscanApplyOutcome(
            submittedRaw: rawValue,
            confirmedRaw: confirmedRaw,
            wasExperimentalForce: !nativeSupported
        ))
    }

    private func lookupMPDisplay(symbols: ResolvedSymbols, displayID: CGDirectDisplayID) -> AnyObject? {
        let manager = symbols.mgrClass.init()
        typealias Fn = @convention(c) (AnyObject, Selector, Int32) -> AnyObject?
        let fn = unsafeBitCast(symbols.displayWithID.imp, to: Fn.self)
        return fn(manager, symbols.displayWithID.selector, Int32(bitPattern: displayID))
    }

    private func callBoolGetter(_ method: VerifiedMethod, on target: AnyObject) -> Bool {
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let fn = unsafeBitCast(method.imp, to: Fn.self)
        return fn(target, method.selector)
    }

    private func callIntGetter(_ method: VerifiedMethod, on target: AnyObject) -> Int32 {
        typealias Fn = @convention(c) (AnyObject, Selector) -> Int32
        let fn = unsafeBitCast(method.imp, to: Fn.self)
        return fn(target, method.selector)
    }

    private func callIntSetter(_ method: VerifiedMethod, on target: AnyObject, value: Int32) {
        typealias Fn = @convention(c) (AnyObject, Selector, Int32) -> Void
        let fn = unsafeBitCast(method.imp, to: Fn.self)
        fn(target, method.selector, value)
    }

    private func makeCapability(
        _ availability: UnderscanAvailability,
        readbackAvailable: Bool,
        confirmedRaw: Int32?
    ) -> UnderscanCapability {
        UnderscanCapability(
            availability: availability,
            architecture: hostArchitecture,
            osVersion: osVersion,
            readbackAvailable: readbackAvailable,
            hardwareConfirmedRaw: confirmedRaw
        )
    }

    // MARK: - Dynamic Loading & Objective-C Type Encoding Verification

    private static func resolveMonitorPanel() -> ResolutionState {
        guard dlopen(frameworkPath, RTLD_LAZY) != nil else {
            log.error("MonitorPanel.framework could not be loaded via dlopen")
            return .frameworkUnavailable("MonitorPanel.framework")
        }
        guard let mgrClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type else {
            return .symbolMissing("MPDisplayMgr")
        }
        guard let displayClass: AnyClass = NSClassFromString("MPDisplay") else {
            return .symbolMissing("MPDisplay")
        }

        guard let displayWithID = verifyMethod(
            on: mgrClass,
            selectorName: "displayWithID:",
            returnPrefixes: ["@"],
            argPrefixes: ["i"]
        ) else {
            return classifyFailure(on: mgrClass, selectorName: "MPDisplayMgr.displayWithID:")
        }
        guard let supportsUnderscan = verifyMethod(
            on: displayClass,
            selectorName: "supportsUnderscan",
            returnPrefixes: ["B", "c"],
            argPrefixes: []
        ) else {
            return classifyFailure(on: displayClass, selectorName: "MPDisplay.supportsUnderscan")
        }
        guard let minUnderscan = verifyMethod(
            on: displayClass,
            selectorName: "minUnderscan",
            returnPrefixes: ["i"],
            argPrefixes: []
        ) else {
            return classifyFailure(on: displayClass, selectorName: "MPDisplay.minUnderscan")
        }
        guard let maxUnderscan = verifyMethod(
            on: displayClass,
            selectorName: "maxUnderscan",
            returnPrefixes: ["i"],
            argPrefixes: []
        ) else {
            return classifyFailure(on: displayClass, selectorName: "MPDisplay.maxUnderscan")
        }
        guard let underscanGetter = verifyMethod(
            on: displayClass,
            selectorName: "underscan",
            returnPrefixes: ["i"],
            argPrefixes: []
        ) else {
            return classifyFailure(on: displayClass, selectorName: "MPDisplay.underscan")
        }
        guard let setUnderscan = verifyMethod(
            on: displayClass,
            selectorName: "setUnderscan:",
            returnPrefixes: ["v"],
            argPrefixes: ["i"]
        ) else {
            return classifyFailure(on: displayClass, selectorName: "MPDisplay.setUnderscan:")
        }

        return .ready(ResolvedSymbols(
            mgrClass: mgrClass,
            displayWithID: displayWithID,
            supportsUnderscan: supportsUnderscan,
            minUnderscan: minUnderscan,
            maxUnderscan: maxUnderscan,
            underscanGetter: underscanGetter,
            setUnderscan: setUnderscan
        ))
    }

    private static func verifyMethod(
        on cls: AnyClass,
        selectorName: String,
        returnPrefixes: [String],
        argPrefixes: [String]
    ) -> VerifiedMethod? {
        let sel = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(cls, sel) else { return nil }
        guard method_getNumberOfArguments(method) == UInt32(2 + argPrefixes.count) else { return nil }

        let retPtr = method_copyReturnType(method)
        let retType = String(cString: retPtr)
        free(retPtr)
        guard returnPrefixes.contains(where: { retType.hasPrefix($0) }) else { return nil }

        for (index, prefix) in argPrefixes.enumerated() {
            guard let argPtr = method_copyArgumentType(method, UInt32(index + 2)) else { return nil }
            let argType = String(cString: argPtr)
            free(argPtr)
            guard argType.hasPrefix(prefix) else { return nil }
        }

        return VerifiedMethod(selector: sel, imp: method_getImplementation(method))
    }

    private static func classifyFailure(on cls: AnyClass, selectorName: String) -> ResolutionState {
        let rawSel = selectorName.split(separator: ".").last.map(String.init) ?? selectorName
        if class_getInstanceMethod(cls, NSSelectorFromString(rawSel)) == nil {
            return .symbolMissing(selectorName)
        }
        return .invalidSignature(selectorName)
    }
}
