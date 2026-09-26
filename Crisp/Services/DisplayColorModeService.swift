import CoreGraphics
import ColorSync
import Foundation
import ObjectiveC.runtime
import QuartzCore
import os

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

    private var applyingUUIDs: Set<String> = []

    /// Persist only a verified selection. Explicitly selecting the current mode also opts in.
    func selectMode(_ mode: DisplayColorMode, for display: DisplayInfo) async -> DisplayColorModeSnapshot? {
        guard isCurrentDisplay(display), !applyingUUIDs.contains(display.displayUUID) else { return nil }
        applyingUUIDs.insert(display.displayUUID)
        defer { applyingUUIDs.remove(display.displayUUID) }
        let saved = SavedColorMode(mode, timing: currentTiming(for: display.displayID))
        guard let data = try? JSONEncoder().encode(saved),
              let context = modeContext(for: display.displayID),
              let target = context.compatibleModes.first(where: { $0.mode.id == mode.id && saved.matches($0.mode) }),
              let snapshot = await applyMode(target, in: context, for: display.displayID) else { return nil }
        UserDefaults.standard.set(data, forKey: Self.preferenceKey(for: display.displayUUID))
        return snapshot
    }

    func hasSavedMode(for display: DisplayInfo) -> Bool {
        !display.isBuiltin && preferredMode(for: display.displayUUID) != nil
    }

    /// Automatic releases Crisp's override; macOS chooses on subsequent display changes.
    func useAutomaticMode(for display: DisplayInfo) {
        UserDefaults.standard.removeObject(forKey: Self.preferenceKey(for: display.displayUUID))
    }

    /// No private display work or delayed task is started for displays without a choice.
    func restoreAtLaunchIfNeeded(using manager: DisplayManager) {
        guard manager.displays.contains(where: { hasSavedMode(for: $0) }) else { return }
        Task { [weak manager] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let manager else { return }
            for display in manager.displays where hasSavedMode(for: display) {
                await restoreAndNotify(for: display)
            }
        }
    }

    /// Keep resolution restores detached and the existing wake passes unblocked.
    func restoreAfterWakeIfNeeded(for display: DisplayInfo) {
        let resolutionRestore = ResolutionService.shared.restoreModeAfterWakeIfNeeded(for: display.displayID)
        guard hasSavedMode(for: display) else { return }
        Task {
            guard await resolutionRestore?.value != false else { return }
            if resolutionRestore != nil { try? await Task.sleep(nanoseconds: 250_000_000) }
            await restoreAndNotify(for: display)
        }
    }

    /// Try once after CG reports a connection. Log missing CADisplay data rather than retrying.
    func restoreAfterConnectionIfNeeded(for display: DisplayInfo) {
        guard hasSavedMode(for: display) else { return }
        Task { await restoreAndNotify(for: display) }
    }

    private func restoreAndNotify(for display: DisplayInfo) async {
        if await restoreSavedModeIfNeeded(for: display) {
            NotificationCenter.default.post(name: .crispDisplayColorModeNeedsRefresh, object: nil)
        }
    }

    /// Resolve a saved format by attributes, only at its recorded timing.
    func restoreSavedModeIfNeeded(for display: DisplayInfo) async -> Bool {
        guard !display.isBuiltin, let saved = preferredMode(for: display.displayUUID),
              !applyingUUIDs.contains(display.displayUUID),
              isCurrentDisplay(display),
              saved.matchesCurrentTiming(currentTiming(for: display.displayID)) else { return false }
        guard let context = modeContext(for: display.displayID) else {
            Self.log.notice("display \(display.displayID, privacy: .public): CG display online but CADisplay color modes unavailable; no retry scheduled")
            return false
        }
        guard let target = context.compatibleModes.first(where: { saved.matches($0.mode) }) else {
            Self.log.notice("display \(display.displayID, privacy: .public): saved color mode unavailable for current timing")
            return false
        }
        guard target.mode.id != context.current.id else { return false }
        applyingUUIDs.insert(display.displayUUID)
        defer { applyingUUIDs.remove(display.displayUUID) }
        guard await applyMode(target, in: context, for: display.displayID) != nil else {
            Self.log.warning("display \(display.displayID, privacy: .public): color mode restore did not take effect")
            return false
        }
        Self.log.notice("display \(display.displayID, privacy: .public): restored saved color mode to \(target.mode.summary, privacy: .public)")
        return true
    }

    /// A queued wake/connection task must not target an ID reassigned to another monitor.
    private func isCurrentDisplay(_ display: DisplayInfo) -> Bool {
        guard CGDisplayIsOnline(display.displayID) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(display.displayID) else { return false }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String == display.displayUUID
    }

    private func currentTiming(for displayID: CGDirectDisplayID) -> DisplayTiming? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return DisplayTiming(width: mode.width, height: mode.height,
                             pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                             refreshRate: mode.refreshRate)
    }

    private func preferredMode(for uuid: String) -> SavedColorMode? {
        guard let data = UserDefaults.standard.data(forKey: Self.preferenceKey(for: uuid)) else { return nil }
        return try? JSONDecoder().decode(SavedColorMode.self, from: data)
    }

    private static func preferenceKey(for uuid: String) -> String {
        "crisp.DisplayColorMode.preferred.\(uuid)"
    }

    func snapshot(for display: DisplayInfo) -> DisplayColorModeSnapshot? {
        guard !display.isBuiltin else { return nil }
        return snapshot(for: display.displayID)
    }

    private func snapshot(for displayID: CGDirectDisplayID) -> DisplayColorModeSnapshot? {
        guard let context = modeContext(for: displayID) else { return nil }
        return DisplayColorModeSnapshot(
            current: context.current,
            compatibleModes: context.compatibleModes.map { $0.mode }
        )
    }

    /// setCurrentMode: is void. Confirm the requested mode from refreshed CADisplay data,
    /// allowing its asynchronous update to settle before persisting or updating the checkmark.
    private func applyMode(
        _ target: (object: NSObject, mode: DisplayColorMode),
        in context: ModeContext,
        for displayID: CGDirectDisplayID
    ) async -> DisplayColorModeSnapshot? {
        if target.mode.id == context.current.id {
            return DisplayColorModeSnapshot(current: context.current, compatibleModes: context.compatibleModes.map { $0.mode })
        }
        let selector = NSSelectorFromString("setCurrentMode:")
        guard let klass = object_getClass(context.display),
              let method = class_getInstanceMethod(klass, selector) else { return nil }
        typealias SetCurrentMode = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let implementation = unsafeBitCast(method_getImplementation(method), to: SetCurrentMode.self)
        implementation(context.display, selector, target.object)
        for attempt in 0...20 {
            if let snapshot = snapshot(for: displayID), snapshot.current.id == target.mode.id,
               SavedColorMode(target.mode, timing: nil).matches(snapshot.current) {
                return snapshot
            }
            guard attempt < 20, !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func modeContext(for displayID: CGDirectDisplayID) -> ModeContext? {
        guard let display = displayEntry(for: displayID), display.external else { return nil }
        let updateSelector = NSSelectorFromString("update")
        guard display.object.responds(to: updateSelector),
              display.object.responds(to: NSSelectorFromString("setCurrentMode:")) else { return nil }
        _ = display.object.perform(updateSelector)

        guard let activeObject = readValue(display.object, "currentMode") as? NSObject,
              let current = makeMode(activeObject),
              let rawModes = readValue(display.object, "availableModes") as? [NSObject] else {
            return nil
        }

        let compatibleModes = rawModes.compactMap { object -> (object: NSObject, mode: DisplayColorMode)? in
            guard let mode = makeMode(object), current.sameTiming(as: mode) else { return nil }
            return (object, mode)
        }
        return ModeContext(display: display.object, current: current, compatibleModes: compatibleModes)
    }

    private func displayEntry(for displayID: CGDirectDisplayID) -> DisplayEntry? {
        guard let displayClass = NSClassFromString("CADisplay") else { return nil }
        guard let classObject = displayClass as AnyObject as? NSObject else { return nil }
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
