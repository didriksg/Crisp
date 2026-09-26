import CoreGraphics
import Foundation
import ObjectiveC.runtime
import QuartzCore
import os

/// One CADisplay color-format variant for an otherwise identical display timing.
struct DisplayColorMode: Identifiable, Equatable, Sendable {
    let id: UInt64
    let width: Int
    let height: Int
    let refreshRate: Double
    let bitDepth: Int
    let colorMode: String
    let hdrMode: String

    var title: String {
        String(format: NSLocalizedString("%d-bit", comment: "Display color mode bit depth"), bitDepth)
    }

    var colorEncoding: String {
        if colorMode.contains("YCbCr444") { return "YCbCr 4:4:4" }
        if colorMode.contains("YCbCr422") { return "YCbCr 4:2:2" }
        if colorMode.contains("YCbCr420") { return "YCbCr 4:2:0" }
        if colorMode.localizedCaseInsensitiveContains("YCbCr") { return "YCbCr" }
        if colorMode.localizedCaseInsensitiveContains("RGB") { return "RGB" }
        return colorMode
    }

    var rangeLabel: String? {
        if colorMode.localizedCaseInsensitiveContains("FullRange") {
            return String(localized: "Full Range")
        }
        if colorMode.localizedCaseInsensitiveContains("LimitedRange") {
            return String(localized: "Limited Range")
        }
        return nil
    }

    var badges: [String] {
        [hdrMode, colorEncoding, rangeLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    var summary: String {
        ([title] + badges).joined(separator: " ")
    }

    /// Keeps the section subtitle compact; encoding and range remain visible as badges below.
    var shortSummary: String {
        [title, hdrMode].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct DisplayColorModeSnapshot: Equatable, Sendable {
    /// The display's current mode after refreshing its CADisplay instance.
    let current: DisplayColorMode
    let compatibleModes: [DisplayColorMode]
    /// Setting is available when the current timing has another compatible mode ID.
    var canSet: Bool { compatibleModes.contains { $0.id != current.id } }
}

/// Reads and switches CADisplay's private color-format modes. Missing selectors or
/// unexpected values hide the control; incompatible private API changes may still fail.
@MainActor
final class DisplayColorModeService {
    static let shared = DisplayColorModeService()
    private static let log = Logger(subsystem: "com.crisp.app", category: "display")
    private init() {}

    private struct DisplayEntry {
        let object: NSObject
        let external: Bool
    }

    private struct ModeContext {
        let display: NSObject
        let current: DisplayColorMode
        let compatibleModes: [(object: NSObject, mode: DisplayColorMode)]
    }

    /// Color-mode IDs can change when WindowServer rebuilds the mode list.
    private struct SavedColorMode: Codable {
        private struct DisplayTiming: Codable {
            let width: Int
            let height: Int
            let pixelWidth: Int
            let pixelHeight: Int
            let refreshRate: Double

            init?(_ displayID: CGDirectDisplayID) {
                guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
                width = mode.width
                height = mode.height
                pixelWidth = mode.pixelWidth
                pixelHeight = mode.pixelHeight
                refreshRate = mode.refreshRate
            }

            func matches(_ displayID: CGDirectDisplayID) -> Bool {
                guard let mode = CGDisplayCopyDisplayMode(displayID) else { return false }
                return width == mode.width && height == mode.height
                    && pixelWidth == mode.pixelWidth && pixelHeight == mode.pixelHeight
                    && (refreshRate == 0 || mode.refreshRate == 0
                        || abs(refreshRate - mode.refreshRate) < 1.0)
            }
        }

        let width: Int
        let height: Int
        let refreshRate: Double
        let bitDepth: Int
        let colorMode: String
        let hdrMode: String
        private let timing: DisplayTiming?

        init(_ mode: DisplayColorMode, displayID: CGDirectDisplayID) {
            width = mode.width
            height = mode.height
            refreshRate = mode.refreshRate
            bitDepth = mode.bitDepth
            colorMode = mode.colorMode
            hdrMode = mode.hdrMode
            timing = DisplayTiming(displayID)
        }

        func matchesCurrentTiming(_ displayID: CGDirectDisplayID) -> Bool {
            timing?.matches(displayID) ?? true
        }

        func matches(_ mode: DisplayColorMode) -> Bool {
            width == mode.width
                && height == mode.height
                && abs(refreshRate - mode.refreshRate) < 0.02
                && bitDepth == mode.bitDepth
                && colorMode.caseInsensitiveCompare(mode.colorMode) == .orderedSame
                && hdrMode.caseInsensitiveCompare(mode.hdrMode) == .orderedSame
        }
    }

    /// Stores a requested Crisp selection by stable display UUID, not its volatile mode ID.
    func selectMode(_ mode: DisplayColorMode, for display: DisplayInfo) -> Bool {
        let saved = SavedColorMode(mode, displayID: display.displayID)
        guard let data = try? JSONEncoder().encode(saved),
              setColorMode(mode.id, for: display.displayID) else { return false }
        UserDefaults.standard.set(data, forKey: Self.preferenceKey(for: display.displayUUID))
        return true
    }

    /// Requests the saved Crisp selection when its recorded timing matches, or when
    /// no timing was recorded.
    /// The saved choice determines the target; the refreshed current mode determines compatibility.
    func restoreSavedModeIfNeeded(for display: DisplayInfo) -> Bool {
        guard !display.isBuiltin, let saved = preferredMode(for: display.displayUUID),
              saved.matchesCurrentTiming(display.displayID) else { return false }
        guard let context = modeContext(for: display.displayID),
              let target = context.compatibleModes.first(where: { saved.matches($0.mode) }) else {
            Self.log.notice("display \(display.displayID, privacy: .public): saved color mode unavailable for current timing")
            return false
        }
        guard applyMode(target.object, on: context.display) else {
            Self.log.warning("display \(display.displayID, privacy: .public): color mode restore request failed")
            return false
        }

        Self.log.notice("display \(display.displayID, privacy: .public): restoring saved color mode to \(target.mode.summary, privacy: .public)")
        return true
    }

    private func preferredMode(for uuid: String) -> SavedColorMode? {
        guard let data = UserDefaults.standard.data(forKey: Self.preferenceKey(for: uuid)) else { return nil }
        return try? JSONDecoder().decode(SavedColorMode.self, from: data)
    }

    private static func preferenceKey(for uuid: String) -> String {
        "crisp.DisplayColorMode.preferred.\(uuid)"
    }

    func snapshot(for display: DisplayInfo) -> DisplayColorModeSnapshot? {
        guard let context = modeContext(for: display.displayID) else { return nil }
        return DisplayColorModeSnapshot(
            current: context.current,
            compatibleModes: context.compatibleModes.map { $0.mode }
        )
    }

    /// Re-enumerates before applying and resolves the requested ID among modes
    /// compatible with the current timing. An ID reused for another mode can still match.
    private func setColorMode(_ modeID: UInt64, for displayID: CGDirectDisplayID) -> Bool {
        guard let context = modeContext(for: displayID),
              let targetObject = context.compatibleModes.first(where: { $0.mode.id == modeID })?.object
        else { return false }
        return applyMode(targetObject, on: context.display)
    }

    private func applyMode(_ targetObject: NSObject, on display: NSObject) -> Bool {
        let selector = NSSelectorFromString("setCurrentMode:")
        guard let klass = object_getClass(display),
              let method = class_getInstanceMethod(klass, selector) else { return false }
        typealias SetCurrentMode = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let implementation = unsafeBitCast(method_getImplementation(method), to: SetCurrentMode.self)
        implementation(display, selector, targetObject)
        return true
    }

    private func modeContext(for displayID: CGDirectDisplayID) -> ModeContext? {
        guard let display = displayEntry(for: displayID), display.external else { return nil }
        let updateSelector = NSSelectorFromString("update")
        guard display.object.responds(to: updateSelector) else { return nil }
        _ = display.object.perform(updateSelector)

        guard let activeObject = readValue(display.object, "currentMode") as? NSObject,
              let current = makeMode(activeObject),
              let rawModes = readValue(display.object, "availableModes") as? [NSObject] else {
            return nil
        }

        let compatibleModes = rawModes.compactMap { object -> (object: NSObject, mode: DisplayColorMode)? in
            guard let mode = makeMode(object), sameTiming(current, mode) else { return nil }
            return (object, mode)
        }
        return ModeContext(display: display.object, current: current, compatibleModes: compatibleModes)
    }

    private func displayEntry(for displayID: CGDirectDisplayID) -> DisplayEntry? {
        guard let displayClass = NSClassFromString("CADisplay") else { return nil }
        let classObject = displayClass as AnyObject as! NSObject
        let selector = NSSelectorFromString("displays")
        guard classObject.responds(to: selector),
              let displays = classObject.perform(selector)?.takeUnretainedValue() as? [NSObject] else {
            return nil
        }

        guard let object = displays.first(where: {
            readNumber($0, "displayId")?.uint32Value == displayID
        }) else { return nil }

        return DisplayEntry(
            object: object,
            external: readBoolean(object, "external") ?? false
        )
    }

    private func makeMode(_ object: NSObject) -> DisplayColorMode? {
        guard let id = readNumber(object, "internalRepresentation")?.uint64Value,
              let width = readNumber(object, "width")?.intValue,
              let height = readNumber(object, "height")?.intValue,
              let refreshRate = readNumber(object, "refreshRate")?.doubleValue,
              let bitDepth = readNumber(object, "bitDepth")?.intValue,
              let colorMode = readString(object, "colorMode"),
              let hdrMode = readString(object, "hdrMode") else { return nil }
        return DisplayColorMode(
            id: id,
            width: width,
            height: height,
            refreshRate: refreshRate,
            bitDepth: bitDepth,
            colorMode: colorMode,
            hdrMode: hdrMode
        )
    }

    private func sameTiming(_ lhs: DisplayColorMode, _ rhs: DisplayColorMode) -> Bool {
        lhs.width == rhs.width
            && lhs.height == rhs.height
            && abs(lhs.refreshRate - rhs.refreshRate) < 0.02
            && lhs.hdrMode.caseInsensitiveCompare(rhs.hdrMode) == .orderedSame
    }

    private func readValue(_ object: NSObject, _ key: String) -> Any? {
        let directGetter = NSSelectorFromString(key)
        let booleanGetter = NSSelectorFromString("is\(key.prefix(1).uppercased())\(key.dropFirst())")
        guard object.responds(to: directGetter) || object.responds(to: booleanGetter) else { return nil }
        return object.value(forKey: key)
    }

    private func readNumber(_ object: NSObject, _ key: String) -> NSNumber? {
        readValue(object, key) as? NSNumber
    }

    private func readBoolean(_ object: NSObject, _ key: String) -> Bool? {
        guard let value = readValue(object, key) else { return nil }
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private func readString(_ object: NSObject, _ key: String) -> String? {
        guard let value = readValue(object, key) else { return nil }
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}
