import Foundation

/// Builds the one-shot authorized install without a user-writable source pathname.
/// Only numeric display identifiers and Base64-encoded, validated plist bytes enter the shell.
enum HiDPIOverrideCommand {
    static func install(vendor: UInt32, product: UInt32, scaledModes: [Data]) throws -> String {
        guard !scaledModes.isEmpty, scaledModes.count <= 4_096,
              scaledModes.allSatisfy({ $0.count == 8 }) else { throw InvalidModes() }
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["scale-resolutions": scaledModes], format: .xml, options: 0)
        // Leave ample headroom for Base64 and the shell template below macOS's argument limit.
        guard data.count <= 96 * 1_024 else { throw InvalidModes() }
        let directory = "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-\(String(vendor, radix: 16))"
        let destination = "\(directory)/DisplayProductID-\(String(product, radix: 16))"
        return """
        set -eu
        /bin/mkdir -p '\(directory)'
        stage=$(/usr/bin/mktemp '\(directory)/.crisp-override.XXXXXXXX')
        trap '/bin/rm -f "$stage"' EXIT
        /usr/bin/printf '%s' '\(data.base64EncodedString())' | /usr/bin/base64 -D > "$stage"
        /usr/bin/plutil -lint -s "$stage"
        /bin/chmod 644 "$stage"
        # rename(2) replaces a symlink at the destination, it does not follow it.
        /bin/mv -f "$stage" '\(destination)'
        """
    }

    /// The existing authorization helper expects an already escaped AppleScript literal.
    static func appleScriptLiteral(_ command: String) -> String {
        command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private struct InvalidModes: LocalizedError {
        var errorDescription: String? { "Invalid HiDPI scale resolutions" }
    }
}
