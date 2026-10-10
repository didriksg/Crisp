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
        let base = "/Library/Displays/Contents/Resources/Overrides"
        let directory = "\(base)/DisplayVendorID-\(String(vendor, radix: 16))"
        let destination = "\(directory)/DisplayProductID-\(String(product, radix: 16))"
        return """
        set -eu
        umask 077
        ensure_directory() {
            if [ ! -e "$1" ] && [ ! -L "$1" ]; then /bin/mkdir -m 755 "$1"; fi
            [ -d "$1" ] && [ ! -L "$1" ] || exit 1
            [ "$(/usr/bin/stat -f %u "$1")" = 0 ] || exit 1
            mode=$(/usr/bin/stat -f %Lp "$1")
            [ "$((0$mode & 022))" = 0 ] || exit 1
            # Mode bits alone do not rule out an ACL granting another user write access.
            /bin/ls -lde "$1" | /usr/bin/awk 'NR > 1 { bad = 1 } END { exit bad }' || exit 1
        }
        for directory in / /Library /Library/Displays /Library/Displays/Contents \
            /Library/Displays/Contents/Resources '\(base)' '\(directory)'; do
            ensure_directory "$directory"
        done
        destination='\(destination)'
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            [ -f "$destination" ] && [ ! -L "$destination" ] || exit 1
            [ "$(/usr/bin/stat -f %u "$destination")" = 0 ] || exit 1
            mode=$(/usr/bin/stat -f %Lp "$destination")
            [ "$((0$mode & 022))" = 0 ] || exit 1
        fi
        stage=$(/usr/bin/mktemp '\(directory)/.crisp-override.XXXXXXXX')
        trap '/bin/rm -f "$stage"' EXIT
        trap 'exit 1' HUP INT TERM
        /usr/bin/printf '%s' '\(data.base64EncodedString())' | /usr/bin/base64 -D > "$stage"
        /usr/bin/plutil -lint -s "$stage"
        /usr/sbin/chown 0:0 "$stage"
        /bin/chmod 644 "$stage"
        /bin/mv -f "$stage" "$destination"
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
