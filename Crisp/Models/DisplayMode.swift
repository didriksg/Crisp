import Foundation
import CoreGraphics

struct DisplayMode: Identifiable, Equatable {
    /// Unique identifier: IODisplayModeID
    let id: Int32
    /// Logical width/height in points
    let width: Int
    let height: Int
    /// Physical pixel width (HiDPI: 2× logical)
    let pixelWidth: Int
    let pixelHeight: Int
    /// Refresh rate in Hz (0 means display default, shown as 60)
    let refreshRate: Double
    let isHiDPI: Bool
    /// Whether this is the native (highest pixel resolution) mode
    let isNative: Bool
    /// Whether this is the variable-refresh member of a duplicate mode pair
    /// (see VariableRefreshModes); shown as "Variable (up to NHz)" like System Settings.
    var isVariableRefresh: Bool = false
    /// Raw IODisplayModeID for CGConfigureDisplayWithDisplayMode (same as id)
    var ioDisplayModeID: Int32 { id }

    // MARK: - Display strings

    var resolutionString: String {
        "\(width)×\(height)"
    }

    var refreshRateString: String {
        RefreshRateFormat.label(refreshRate)
    }

    // MARK: - Enumeration helpers

    /// Prefers the max pixelWidth among non-HiDPI modes (pixelWidth == width),
    /// falling back to the global max if all modes are HiDPI.
    private static func nativePixelWidth(from rawModes: [CGDisplayMode]) -> Int {
        rawModes.filter { $0.pixelWidth == $0.width }.map { $0.pixelWidth }.max()
            ?? rawModes.map { $0.pixelWidth }.max() ?? 0
    }

    /// Returns all display modes for the given display, sorted by logical width descending.
    static func availableModes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let rawModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
              !rawModes.isEmpty else {
            return []
        }

        let maxPixelWidth = nativePixelWidth(from: rawModes)
        let variableIDs = VariableRefreshModes.variableModeIDs(from: cgsModeRecords(for: displayID))

        var seen = Set<Int32>()
        var modes: [DisplayMode] = rawModes.compactMap { mode -> DisplayMode? in
            let modeID = mode.ioDisplayModeID
            guard seen.insert(modeID).inserted else { return nil }
            guard mode.isUsableForDesktopGUI() else { return nil }

            let w = mode.width
            let h = mode.height
            let pw = mode.pixelWidth
            let ph = mode.pixelHeight
            let refresh = mode.refreshRate

            return DisplayMode(
                id: modeID,
                width: w,
                height: h,
                pixelWidth: pw,
                pixelHeight: ph,
                refreshRate: refresh,
                isHiDPI: pw > w,
                isNative: pw >= maxPixelWidth,
                isVariableRefresh: variableIDs.contains(modeID)
            )
        }

        // Merge in every GPU-scaled HiDPI mode CG hides (cgsHiddenHiDPIModes): CGS carries
        // these panel-native scaled resolutions with no override, like BetterDisplay applies them.
        let knownIDs = Set(modes.map { $0.id })
        let nativeAR = DisplayModeGeometry.nativeAspect(from: rawModes.map {
            DisplayModeGeometry(width: $0.width, height: $0.height,
                                pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
        })
        modes += cgsHiddenHiDPIModes(for: displayID, excludingIDs: knownIDs,
                                     maxPixelWidth: maxPixelWidth, nativeAspect: nativeAR,
                                     variableIDs: variableIDs)

        return modes.sorted { lhs, rhs in
            if lhs.width != rhs.width { return lhs.width > rhs.width }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            if lhs.refreshRate != rhs.refreshRate { return lhs.refreshRate > rhs.refreshRate }
            // Variable above its same-rate fixed twin, matching System Settings.
            if lhs.isVariableRefresh != rhs.isVariableRefresh { return lhs.isVariableRefresh }
            if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
            return false
        }
    }

    /// The raw CGS mode table reduced to what the VRR detector needs.
    private static func cgsModeRecords(for displayID: CGDirectDisplayID) -> [VRRModeRecord] {
        var count: Int32 = 0
        guard CGSGetNumberOfDisplayModes(displayID, &count) == .success, count > 0 else { return [] }
        let length = Int32(MemoryLayout<CGSDisplayModeDescription>.size)
        var out: [VRRModeRecord] = []
        for i in 0..<count {
            var d = CGSDisplayModeDescription()
            guard CGSGetDisplayModeDescriptionOfLength(displayID, i, &d, length) == .success else { continue }
            out.append(VRRModeRecord(id: Int32(bitPattern: d.modeNumber),
                                     width: Int(d.width), height: Int(d.height),
                                     freq: Int(d.freq), density: d.density, flags: d.flags))
        }
        return out
    }

    /// GPU-scaled HiDPI modes CG omits entirely; the private CGS list still carries them
    /// with no override plist. Same id space as CG, so ResolutionService applies them via
    /// CGSConfigureDisplayMode directly: no override write, reconnect, or blank.
    private static func cgsHiddenHiDPIModes(for displayID: CGDirectDisplayID,
                                            excludingIDs known: Set<Int32>,
                                            maxPixelWidth: Int,
                                            nativeAspect: Double,
                                            variableIDs: Set<Int32>) -> [DisplayMode] {
        var count: Int32 = 0
        guard CGSGetNumberOfDisplayModes(displayID, &count) == .success, count > 0 else { return [] }
        let length = Int32(MemoryLayout<CGSDisplayModeDescription>.size)

        var out: [DisplayMode] = []
        for i in 0..<count {
            var d = CGSDisplayModeDescription()
            guard CGSGetDisplayModeDescriptionOfLength(displayID, i, &d, length) == .success else { continue }
            if d.flags & 0x40000000 != 0 { continue }   // macOS-unusable (isUsableForDesktopGUI == false)
            guard d.density >= 1.5 else { continue }      // HiDPI (2x backing) only
            let id = Int32(bitPattern: d.modeNumber)
            if known.contains(id) { continue }            // already surfaced by CG
            let w = Int(d.width), h = Int(d.height)
            // Panel aspect only: CGS also lists off-aspect HiDPI modes (e.g. 4:3 on a 16:9 panel)
            // that render pillar-boxed; drop them, the way the built-in notch filter does.
            if nativeAspect > 0, abs(Double(w) / Double(h) - nativeAspect) / nativeAspect >= 0.02 { continue }
            let pw = Int((Float(d.width) * d.density).rounded())
            let ph = Int((Float(d.height) * d.density).rounded())
            out.append(DisplayMode(id: id, width: w, height: h,
                                   pixelWidth: pw, pixelHeight: ph,
                                   refreshRate: Double(d.freq),
                                   isHiDPI: pw > w, isNative: pw >= maxPixelWidth,
                                   isVariableRefresh: variableIDs.contains(id)))
        }
        return out
    }

    static func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }

        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let allModes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
        let maxPixelWidth = nativePixelWidth(from: allModes)

        let w = mode.width
        let h = mode.height
        let pw = mode.pixelWidth
        let ph = mode.pixelHeight
        let refresh = mode.refreshRate
        let modeID = mode.ioDisplayModeID
        let variableIDs = VariableRefreshModes.variableModeIDs(from: cgsModeRecords(for: displayID))

        return DisplayMode(
            id: modeID,
            width: w,
            height: h,
            pixelWidth: pw,
            pixelHeight: ph,
            refreshRate: refresh,
            isHiDPI: pw > w,
            isNative: pw >= maxPixelWidth,
            isVariableRefresh: variableIDs.contains(modeID)
        )
    }
}
