// Turns one display through the given rotations and back, and prints what every online
// display looks like after each step: mode, rotation, origin. Also times the call and counts
// the reconfiguration callbacks it fires (#258).
//
//   swiftc -O scripts/rotation-probe.swift -o /tmp/rotation-probe \
//     -Xlinker -U -Xlinker _SLSSetDisplayRotation
//   /tmp/rotation-probe <displayID> 90 180 270 0
import AppKit
import CoreGraphics
import Foundation

@_silgen_name("SLSSetDisplayRotation")
func SLSSetDisplayRotation(_ display: CGDirectDisplayID, _ rotation: Int32) -> CGError

func online() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func describe() -> String {
    online().map { id in
        let mode = CGDisplayCopyDisplayMode(id)
        let bounds = CGDisplayBounds(id)
        let main = CGDisplayIsMain(id) != 0 ? " main" : ""
        return "  \(id)\(main): mode \(mode?.ioDisplayModeID ?? -1) \(mode?.width ?? 0)x\(mode?.height ?? 0)"
            + " rot \(Int(CGDisplayRotation(id))) origin \(Int(bounds.minX)),\(Int(bounds.minY))"
            + " size \(Int(bounds.width))x\(Int(bounds.height))"
    }.joined(separator: "\n")
}

_ = NSApplication.shared  // a WindowServer connection; a bare tool gets no reconfiguration callbacks
var callbacks = 0
let screenNote = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in print("    didChangeScreenParameters") }
CGDisplayRegisterReconfigurationCallback({ id, flags, _ in
    if !flags.contains(.beginConfigurationFlag) { callbacks += 1 }
    print("    callback display \(id) flags 0x\(String(flags.rawValue, radix: 16))")
}, nil)

let args = CommandLine.arguments
guard args.count >= 3, let target = CGDirectDisplayID(args[1]) else {
    print("usage: rotation-probe <displayID> <deg> [<deg> ...]")
    exit(2)
}
print("before:\n\(describe())")
for degrees in args.dropFirst(2).compactMap({ Int32($0) }) {
    callbacks = 0
    let start = Date()
    let err = SLSSetDisplayRotation(target, degrees)
    let ms = Date().timeIntervalSince(start) * 1000
    print("set \(target) to \(degrees): err \(err.rawValue), call took \(String(format: "%.1f", ms)) ms")
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    print("after 3 s (\(callbacks) callbacks):\n\(describe())")
}
