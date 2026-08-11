// VRR mode probe for issue #31: on a variable-refresh-rate external display the
// mode list carries two entries at the same nominal Hz (one fixed, one VRR), and
// nothing in the fields Crisp currently parses out of CGSDisplayModeDescription
// distinguishes them. macOS's own Displays pane classifies per mode via the same
// private CGSGetDisplayModeDescriptionOfLength call, so the bit is somewhere in
// the ~190 bytes of the struct we have not mapped. This probe hex-dumps the FULL
// raw struct for every mode of every display so the two duplicate entries can be
// diffed byte-for-byte on real VRR hardware.
//
// Run: swift scripts/vrr-probe.swift
// Paste the whole output into the issue; it contains no personal data, only
// display timing tables.
import AppKit

@_silgen_name("CGSGetNumberOfDisplayModes")
func CGSGetNumberOfDisplayModes(_ display: CGDirectDisplayID, _ nModes: UnsafeMutablePointer<Int32>) -> CGError

@_silgen_name("CGSGetDisplayModeDescriptionOfLength")
func CGSGetDisplayModeDescriptionOfLength(_ display: CGDirectDisplayID, _ idx: Int32,
                                          _ mode: UnsafeMutableRawPointer, _ length: Int32) -> CGError

// Keep in sync with CGSDisplayModeDescription in Crisp-Bridging-Header.h.
let structLength: Int32 = 212

func hexDump(_ bytes: UnsafeRawBufferPointer) {
    for offset in stride(from: 0, to: bytes.count, by: 16) {
        let row = (offset..<min(offset + 16, bytes.count))
            .map { String(format: "%02x", bytes[$0]) }
            .joined(separator: " ")
        print(String(format: "    %3d: %@", offset, row))
    }
}

var displayCount: UInt32 = 0
var displays = [CGDirectDisplayID](repeating: 0, count: 16)
CGGetOnlineDisplayList(16, &displays, &displayCount)

for display in displays.prefix(Int(displayCount)) {
    let builtin = CGDisplayIsBuiltin(display) != 0
    print("=== display \(display) (\(builtin ? "built-in" : "external")) ===")

    // Current VRR state of the active mode, for cross-reference (macOS 12+).
    if let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display
    }) {
        let minHz = 1.0 / screen.maximumRefreshInterval
        let maxHz = 1.0 / screen.minimumRefreshInterval
        print(String(format: "active mode refresh range: %.2f - %.2f Hz%@",
                     minHz, maxHz, minHz < maxHz ? "  <-- VRR active" : " (fixed)"))
    }

    // Public enumeration, to pair ioDisplayModeID with the private list below.
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    if let modes = CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode] {
        print("-- public CGDisplayCopyAllDisplayModes --")
        for mode in modes {
            print(String(format: "  ioModeID=%6d  %5dx%-5d %7.2fHz  ioFlags=0x%08x",
                         mode.ioDisplayModeID, mode.width, mode.height,
                         mode.refreshRate, mode.ioFlags))
        }
    }

    var modeCount: Int32 = 0
    guard CGSGetNumberOfDisplayModes(display, &modeCount) == .success else {
        print("  CGSGetNumberOfDisplayModes failed"); continue
    }
    print("-- private CGS mode descriptions (\(modeCount) modes, raw \(structLength) bytes each) --")
    for index in 0..<modeCount {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(structLength), alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(structLength))
        guard CGSGetDisplayModeDescriptionOfLength(display, index, buffer, structLength) == .success else {
            print("  [\(index)] description call failed"); continue
        }
        // Known offsets, for orientation while reading the dump.
        let modeNumber = buffer.load(fromByteOffset: 0, as: UInt32.self)
        let width = buffer.load(fromByteOffset: 8, as: UInt32.self)
        let height = buffer.load(fromByteOffset: 12, as: UInt32.self)
        let freq = buffer.load(fromByteOffset: 190, as: UInt16.self)
        print("  [\(index)] modeNumber=\(modeNumber) \(width)x\(height) freq=\(freq)Hz")
        hexDump(UnsafeRawBufferPointer(start: buffer, count: Int(structLength)))
    }
    print("")
}
