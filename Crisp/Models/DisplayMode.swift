import Foundation
import CoreGraphics

/// Represents a single display mode (resolution + refresh rate + HiDPI flag).
struct DisplayMode: Identifiable, Equatable, Sendable {
    /// Unique identifier: IODisplayModeID
    let id: Int32
    /// Logical width in points
    let width: Int
    /// Logical height in points
    let height: Int
    /// Physical pixel width (HiDPI: 2× logical)
    let pixelWidth: Int
    /// Physical pixel height
    let pixelHeight: Int
    /// Refresh rate in Hz (0 means display default, shown as 60)
    let refreshRate: Double
    /// Whether this is a HiDPI (Retina) scaled mode
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

    /// Computes the native pixel width for a set of raw display modes.
    /// Prefers the max pixelWidth among non-HiDPI modes (pixelWidth == width),
    /// falling back to global max if all modes are HiDPI.
    private static func nativePixelWidth(from rawModes: [CGDisplayMode]) -> Int {
        rawModes.filter { $0.pixelWidth == $0.width }.map { $0.pixelWidth }.max()
            ?? rawModes.map { $0.pixelWidth }.max() ?? 0
    }

    /// One WindowServer enumeration, resolved after native-resolution detection
    /// supplies a better aspect ratio. Keeping the unfiltered hidden candidates
    /// lets registry detection and mode discovery run concurrently.
    struct Enumeration: Sendable {
        fileprivate let visibleModes: [DisplayMode]
        fileprivate let hiddenHiDPIModes: [DisplayMode]
        fileprivate let inferredNativeAspect: Double

        func resolved(nativeAspect overrideNativeAspect: Double? = nil) -> [DisplayMode] {
            let nativeAspect = overrideNativeAspect.flatMap { $0 > 0 ? $0 : nil }
                ?? inferredNativeAspect
            let hidden = hiddenHiDPIModes.filter { mode in
                guard nativeAspect > 0 else { return true }
                let aspect = Double(mode.width) / Double(mode.height)
                return abs(aspect - nativeAspect) / nativeAspect < 0.02
            }
            return DisplayMode.sorted(visibleModes + hidden)
        }
    }

    /// Returns all display modes for the given display, sorted by logical width descending.
    /// Pass `includeHiDPI: true` (default) to include all scaled modes.
    static func availableModes(for displayID: CGDirectDisplayID,
                               nativeAspect overrideNativeAspect: Double? = nil) -> [DisplayMode] {
        enumerateModes(for: displayID).resolved(nativeAspect: overrideNativeAspect)
    }

    /// Enumerates visible and CGS-hidden modes without committing to an aspect
    /// filter. The caller can resolve the snapshot once metadata detection ends.
    static func enumerateModes(for displayID: CGDirectDisplayID) -> Enumeration {
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let rawModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
              !rawModes.isEmpty else {
            return Enumeration(visibleModes: [], hiddenHiDPIModes: [], inferredNativeAspect: 0)
        }

        let maxPixelWidth = nativePixelWidth(from: rawModes)
        let variableIDs = VariableRefreshModes.variableModeIDs(from: cgsModeRecords(for: displayID))

        var seen = Set<Int32>()
        let modes: [DisplayMode] = rawModes.compactMap { mode -> DisplayMode? in
            let modeID = mode.ioDisplayModeID
            guard seen.insert(modeID).inserted else { return nil }  // deduplicate
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

        // Merge in every GPU-scaled HiDPI mode CG hides (see cgsHiddenHiDPIModes): the panel's
        // clean scaled resolutions (1600x900, 2048x1152, full 2560x1440 refresh set, ...) that
        // CGS carries without any override, so we can offer and apply them directly like BetterDisplay.
        let knownIDs = Set(modes.map { $0.id })
        let inferredNativeAspect = DisplayModeGeometry.nativeAspect(from: rawModes.map {
            DisplayModeGeometry(width: $0.width, height: $0.height,
                                pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
        })
        let hiddenModes = cgsHiddenHiDPIModes(
            for: displayID, excludingIDs: knownIDs,
            maxPixelWidth: maxPixelWidth, variableIDs: variableIDs)
        return Enumeration(visibleModes: modes, hiddenHiDPIModes: hiddenModes,
                           inferredNativeAspect: inferredNativeAspect)
    }

    private static func sorted(_ modes: [DisplayMode]) -> [DisplayMode] {
        modes.sorted { lhs, rhs in
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

    /// GPU-scaled HiDPI modes that `CGDisplayCopyAllDisplayModes` omits. When a scaled resolution
    /// collides with a real EDID timing (e.g. 1920x1080 HiDPI, whose 3840x2160 backing the panel
    /// advertises as a real 4K timing at only 50/60Hz), CG surfaces just that low-refresh timing
    /// and drops the GPU-scaled full-refresh variant. The private CGS list still carries it.
    /// Return every usable HiDPI mode CG omits (not just refresh variants of sizes CG already
    /// lists): these are the panel's clean scaled resolutions the private CGS list carries with no
    /// override plist, which is exactly what BetterDisplay applies. Same id space as CG
    /// (modeNumber == ioDisplayModeID), so ResolutionService applies them directly via
    /// CGSConfigureDisplayMode: no override write, no reconnect, no blank.
    private static func cgsHiddenHiDPIModes(for displayID: CGDirectDisplayID,
                                            excludingIDs known: Set<Int32>,
                                            maxPixelWidth: Int,
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

    /// Returns the current active display mode.
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
