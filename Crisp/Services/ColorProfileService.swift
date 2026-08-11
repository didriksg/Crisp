import Foundation
import CoreGraphics
@preconcurrency import ColorSync

/// ICC color profile model.
struct ICCProfile: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: URL
    let colorSpaceType: String  // "RGB", "CMYK", "Gray", etc.
    /// ICC device-class signature: "mntr" (display), "prtr" (printer),
    /// "scnr" (scanner), "spac" (color-space conversion), etc. "" if unreadable.
    let deviceClass: String

    /// Whether this profile is safe to assign as a display's ColorSync profile.
    /// Displays take RGB, matrix-based profiles, the monitor ("mntr") and RGB
    /// working-space ("spac") classes. Printer/scanner/CMYK/LUT profiles can make
    /// WindowServer abort while building the display transform, crashing the whole
    /// GUI on every reconnect (recoverable only in Safe Mode; seen on AOC Q27G3XMN),
    /// so they must never be offered or assigned.
    var isDisplayProfile: Bool {
        colorSpaceType == "RGB" && (deviceClass == "mntr" || deviceClass == "spac")
    }

    init(name: String, path: URL, colorSpaceType: String, deviceClass: String) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.colorSpaceType = colorSpaceType
        self.deviceClass = deviceClass
    }

    /// Convenience failable initializer: loads profile metadata from a file URL.
    init?(url: URL) {
        guard let profile = ColorProfileService.makeProfile(from: url) else { return nil }
        self = profile
    }

    static func == (lhs: ICCProfile, rhs: ICCProfile) -> Bool {
        lhs.path == rhs.path
    }
}

/// Service for ICC color profile enumeration and switching.
/// Uses ColorSync framework + file system scanning.
final class ColorProfileService: @unchecked Sendable {
    static let shared = ColorProfileService()
    private init() {}

    // MARK: - Profile Enumeration

    /// Returns the display-assignable ICC profiles for the given display, sorted
    /// alphabetically, matching macOS's own Displays color list: the standard RGB
    /// profiles plus only THIS display's own factory profile. Other monitors'
    /// per-display profiles are hidden. `displayUUID` is `DisplayInfo.displayUUID`.
    func enumerateProfiles(for displayUUID: String) async -> [ICCProfile] {
        await Task.detached(priority: .userInitiated) {
            var profiles: [ICCProfile] = []
            let searchURLs: [URL] = [
                URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
                URL(fileURLWithPath: "/System/Library/ColorSync/Profiles"),
                URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/ColorSync/Profiles")
            ]

            var seenPaths = Set<URL>()
            let fm = FileManager.default

            for dir in searchURLs {
                guard let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                while let url = enumerator.nextObject() as? URL {
                    guard !seenPaths.contains(url) else { continue }
                    let ext = url.pathExtension.lowercased()
                    guard ext == "icc" || ext == "icm" else { continue }
                    seenPaths.insert(url)
                    if let profile = Self.makeProfileImpl(from: url) {
                        profiles.append(profile)
                    }
                }
            }

            // Only offer profiles that are safe to assign to a display. A non-display
            // profile (printer/scanner/CMYK/LUT) crashes WindowServer on assignment.
            return profiles
                .filter { $0.isDisplayProfile }
                .filter { profile in
                    // Match macOS's list: standard profiles show for every display, but
                    // a per-display factory profile (.../ColorSync/Profiles/Displays/)
                    // shows only for the display whose UUID is in its filename. Keeps
                    // other monitors' profiles out of this display's list.
                    let path = profile.path.path
                    guard path.contains("/ColorSync/Profiles/Displays/") else { return true }
                    return path.range(of: displayUUID, options: .caseInsensitive) != nil
                }
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
        }.value
    }

    static func makeProfile(from url: URL) -> ICCProfile? {
        makeProfileImpl(from: url)
    }

    private static func makeProfileImpl(from url: URL) -> ICCProfile? {
        let name: String
        let csType: String
        let deviceClass: String

        if let rawProfile = ColorSyncProfileCreateWithURL(url as CFURL, nil) {
            let profile = rawProfile.takeRetainedValue()
            if let rawDesc = ColorSyncProfileCopyDescriptionString(profile) {
                name = rawDesc.takeRetainedValue() as String
            } else {
                name = url.deletingPathExtension().lastPathComponent
            }
            let sigs = headerSignatures(from: profile)
            csType = friendlyColorSpace(sigs.colorSpace)
            deviceClass = sigs.deviceClass
        } else {
            name = url.deletingPathExtension().lastPathComponent
            csType = "RGB"
            deviceClass = ""  // unreadable header -> treated as non-display, filtered out
        }

        return ICCProfile(name: name, path: url, colorSpaceType: csType, deviceClass: deviceClass)
    }

    /// Reads the ICC header's device-class (bytes 12-15) and data-color-space
    /// (bytes 16-19) signatures, trimmed, e.g. ("mntr", "RGB"). Either is "" when
    /// the header is missing/short or a field isn't printable ASCII.
    private static func headerSignatures(from profile: ColorSyncProfile) -> (deviceClass: String, colorSpace: String) {
        guard let rawData = ColorSyncProfileCopyHeader(profile) else { return ("", "") }
        let data = rawData.takeRetainedValue() as Data
        guard data.count >= 20 else { return ("", "") }
        func sig(_ range: Range<Int>) -> String {
            // The header's 4CC fields come back as host-endian OSTypes, so on a
            // little-endian Mac their bytes are reversed ("rtnm" for "mntr"). Reverse
            // to recover the ASCII signature. (Reading them forward is why the old
            // colorSpaceType always fell through to its "RGB" default.)
            let bytes = Array([UInt8](data[range]).reversed())
            guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
                  let str = String(bytes: bytes, encoding: .ascii) else { return "" }
            return str.trimmingCharacters(in: .whitespaces)
        }
        return (sig(12..<16), sig(16..<20))
    }

    private static func friendlyColorSpace(_ sig: String) -> String {
        // ICC data-color-space signatures are case-sensitive: Lab is "Lab", not "LAB".
        // Unknown spaces must NOT masquerade as "RGB", isDisplayProfile keys on it.
        switch sig {
        case "RGB":  return "RGB"
        case "CMYK": return "CMYK"
        case "GRAY": return "Gray"
        case "Lab":  return "Lab"
        case "XYZ":  return "XYZ"
        default:     return sig.isEmpty ? "Unknown" : sig
        }
    }

    // MARK: - Current Color Info

    /// Returns the human-readable color space name for the given display.
    func currentColorSpaceName(for displayID: CGDirectDisplayID) -> String {
        // CGColorSpace.name exists only for named system spaces; a display's
        // space is an unnamed ICC profile, so ask ColorSync for the profile
        // description (the name System Settings shows, e.g. "Color LCD").
        if let raw = ColorSyncProfileCreateWithDisplayID(displayID) {
            let profile = raw.takeRetainedValue()
            if let rawDesc = ColorSyncProfileCopyDescriptionString(profile) {
                let desc = rawDesc.takeRetainedValue() as String
                if !desc.isEmpty { return desc }
            }
        }
        let colorSpace = CGDisplayCopyColorSpace(displayID)
        guard let cfName = colorSpace.name else { return "Unknown" }
        return humanReadable(cfName as String)
    }

    /// Returns a description like "Internal (8-bit)" for the display's current color mode.
    func colorModeDescription(for displayID: CGDirectDisplayID) -> String {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return "Unknown" }
        let encoding: String
        if let cfEnc = (mode as DisplayModePixelEncoding).pixelEncoding { encoding = cfEnc as String } else { encoding = "" }
        let bpc = bitsPerChannel(from: encoding)
        let source = CGDisplayIsBuiltin(displayID) != 0 ? "Internal" : "External"
        return "\(source) (\(bpc)-bit)"
    }

    private func bitsPerChannel(from encoding: String) -> Int {
        let rCount = encoding.filter { $0 == "R" }.count
        if rCount > 0 { return rCount }
        let dCount = encoding.filter { $0 == "D" }.count
        return dCount >= 30 ? 10 : 8
    }

    // Bridge CGColorSpace CFString constants to Swift String for comparison
    private func humanReadable(_ name: String) -> String {
        if name == (CGColorSpace.displayP3 as String) { return "Display P3" }
        if name == (CGColorSpace.sRGB as String) { return "sRGB IEC61966-2.1" }
        if name == (CGColorSpace.adobeRGB1998 as String) { return "Adobe RGB (1998)" }
        if name == (CGColorSpace.genericRGBLinear as String) { return "Generic RGB Linear" }
        if name == (CGColorSpace.extendedSRGB as String) { return "Extended sRGB" }
        if name == (CGColorSpace.linearSRGB as String) { return "Linear sRGB" }
        if name == (CGColorSpace.extendedLinearSRGB as String) { return "Extended Linear sRGB" }
        if name == (CGColorSpace.genericGrayGamma2_2 as String) { return "Generic Gray Gamma 2.2" }
        if name.hasPrefix("kCGColorSpace") {
            return String(name.dropFirst("kCGColorSpace".count))
        }
        return name
    }

    // MARK: - Current Profile URL

    /// Returns the file URL of the currently active ICC profile for the given display, if available.
    func currentProfileURL(for displayID: CGDirectDisplayID) -> URL? {
        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = rawUUID.takeRetainedValue()

        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else { return nil }

        guard let rawInfo = ColorSyncDeviceCopyDeviceInfo(deviceClass, uuid) else { return nil }
        let info = rawInfo.takeRetainedValue() as NSDictionary

        // Determine the active mode key from FactoryProfiles[DeviceDefaultProfileID].
        // The key is a String on some displays ("HDMI HD") and a Number on
        // others (the builtin registers mode 1), so keep it opaque.
        let factoryProfiles = info["FactoryProfiles"] as? NSDictionary
        guard let activeMode = factoryProfiles?[profileIDKey] else { return nil }

        // CustomProfiles: keys are mode keys, values are NSURL or a URL string.
        if let customProfiles = info["CustomProfiles"] as? NSDictionary,
           let value = customProfiles[activeMode] {
            if let url = value as? NSURL { return url as URL }
            if let str = value as? String { return URL(string: str) }
        }

        // Fall back to FactoryProfiles: the mode entry is a dict with a DeviceProfileURL.
        if let modeDict = factoryProfiles?[activeMode] as? NSDictionary,
           let value = modeDict["DeviceProfileURL"] {
            if let url = value as? NSURL { return url as URL }
            if let str = value as? String { return URL(string: str) }
        }

        return nil
    }

    // MARK: - Profile Switching

    /// Sets the ICC profile for the given display using ColorSync.
    /// Returns true on success.
    @discardableResult
    func setProfile(_ profile: ICCProfile, for displayID: CGDirectDisplayID) -> Bool {
        // Safety net (defends the ColorSyncDeviceSetCustomProfiles call even if a
        // non-display profile reaches here another way): assigning a printer/scanner/
        // CMYK/LUT profile as a display override makes WindowServer abort building the
        // display transform, crashing the whole GUI on every reconnect. Refuse it.
        guard profile.isDisplayProfile else {
            return false
        }

        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return false }
        let uuid = rawUUID.takeRetainedValue()

        // kColorSyncDisplayDeviceClass and kColorSyncDeviceDefaultProfileID are
        // Unmanaged<CFString>? in the current SDK; use takeUnretainedValue() to borrow them.
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else { return false }

        let profileInfo: NSDictionary = [profileIDKey: profile.path as NSURL]

        return ColorSyncDeviceSetCustomProfiles(
            deviceClass,
            uuid,
            profileInfo as CFDictionary
        )
    }
}

/// `CGDisplayMode.pixelEncoding` is deprecated (macOS 10.11, "No longer
/// supported") but still returns real data and is the only source for the
/// panel's bits-per-channel. Reading it through this protocol witness
/// acknowledges the deprecation once instead of warning at every call site.
private protocol DisplayModePixelEncoding {
    var pixelEncoding: CFString? { get }
}
extension CGDisplayMode: DisplayModePixelEncoding {}
