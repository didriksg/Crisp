// Asks OSDUIHelper for the brightness bezel with a given filled/total chiclet
// pair, to see how macOS 14 and 15 draw a value that is not a whole chiclet.
// Measured on 14.8.7 and 15.7.7: the bar fills in proportion to filled/total
// rather than in whole chiclets, so 33/64 sits a quarter of a chiclet past
// 8/16. That is why BrightnessHUDService asks for 64 totals, which puts the
// fill edge on the quarter steps Option+Shift moves in. It still draws sixteen
// segments. macOS 26 never reaches this path: Crisp draws its own capsule
// there (OSDBannerService).
//
// The bezel needs the GUI session, so on a test VM run it through launchctl
// rather than straight from ssh, and build for the VM's own OS version:
//   swiftc -O -target arm64-apple-macos14.0 scripts/osd-chiclet-probe.swift -o /tmp/osd-chiclet-probe
//   sudo -n launchctl asuser 501 /tmp/osd-chiclet-probe <filled> <total> [msecUntilFade]
import AppKit
import CoreGraphics

@objc enum OSDImage: CLong {
    case brightness = 1
}

@objc protocol OSDUIHelperProtocol {
    func showImage(
        _ img: OSDImage,
        onDisplayID displayID: CGDirectDisplayID,
        priority: CUnsignedInt,
        msecUntilFade: CUnsignedInt,
        filledChiclets: CUnsignedInt,
        totalChiclets: CUnsignedInt,
        locked: Bool
    )
}

let args = CommandLine.arguments
guard args.count >= 3, let filled = CUnsignedInt(args[1]), let total = CUnsignedInt(args[2]) else {
    print("usage: osd-chiclet-probe <filled> <total> [msecUntilFade]")
    exit(1)
}
let msec = args.count > 3 ? (CUnsignedInt(args[3]) ?? 6000) : 6000

let conn = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
conn.remoteObjectInterface = NSXPCInterface(with: OSDUIHelperProtocol.self)
conn.resume()

guard let helper = conn.remoteObjectProxyWithErrorHandler({ error in
    print("xpc error: \(error)")
}) as? OSDUIHelperProtocol else {
    print("no helper proxy")
    exit(2)
}

helper.showImage(
    .brightness,
    onDisplayID: CGMainDisplayID(),
    priority: 0x1f4,
    msecUntilFade: msec,
    filledChiclets: filled,
    totalChiclets: total,
    locked: false
)
print("sent filled=\(filled) total=\(total) fade=\(msec)ms")
// The XPC message is one-way; a process that exits at once loses it.
Thread.sleep(forTimeInterval: 1.0)
