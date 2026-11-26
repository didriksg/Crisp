import Foundation

/// The text Copy Debug Info (Advanced Settings > About) puts on the clipboard: what the bug
/// report template asks for, with no serial number or UUID, as the template promises.
enum DebugReport {
    struct Display: Equatable {
        let name: String
        let isBuiltin: Bool
        let isMain: Bool
        let vendor: UInt32
        let model: UInt32
        let mode: String?  // "1280 × 720 HiDPI, 60 Hz"
    }

    /// `allRuns` false: the log covers only Crisp's current run (the reader could not open
    /// the full log store), so the heading says so.
    static func text(crisp: String, macOS: String, mac: String, displays: [Display],
                     log: [String], allRuns: Bool) -> String {
        var lines = ["Crisp \(crisp)", "macOS \(macOS)", "Mac \(mac)", "", "Displays:"]
        for display in displays {
            var kind = [display.isBuiltin ? "built-in" : "external"]
            if display.isMain { kind.append("main") }
            var line = "- \(display.name) (\(kind.joined(separator: ", "))), "
                + "vendor 0x\(String(display.vendor, radix: 16)), model 0x\(String(display.model, radix: 16))"
            if let mode = display.mode { line += ", \(mode)" }
            lines.append(line)
        }
        lines += ["", allRuns ? "Log, last 30 minutes:" : "Log, last 30 minutes of this run of Crisp:"]
        lines += log.isEmpty ? ["(no lines)"] : numberingUUIDs(log)
        return lines.joined(separator: "\n")
    }

    /// Crisp logs display UUIDs as public, and a UUID names one physical monitor. Each one
    /// becomes uuid-1, uuid-2, ... in order of first use, so lines about one display still match.
    private static func numberingUUIDs(_ log: [String]) -> [String] {
        var numbers: [String: Int] = [:]
        return log.map { line in
            line.replacing(/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/) { match in
                let uuid = match.output.uppercased()
                if numbers[uuid] == nil { numbers[uuid] = numbers.count + 1 }
                return "uuid-\(numbers[uuid]!)"
            }
        }
    }
}
