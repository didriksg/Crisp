import Foundation

/// Which active display entries have a real screen behind them. macOS lists entries with
/// nothing behind them around sleep, wake and undock, and each shape measured so far is a
/// row in ScreenCountTests: a new field report adds a row there, not a predicate in a
/// service. See docs/display-notes.md (phantomAwareActiveDisplayCount).
enum ScreenCount {
    /// One entry of the active display list, as CoreGraphics reports it.
    struct Entry: Equatable {
        let id: UInt32
        let isCrispVirtual: Bool
        let isBuiltin: Bool
        let vendor: UInt32
        let model: UInt32
    }

    /// One DisplayPort, Thunderbolt or USB-C transport node in the I/O registry.
    struct PortNode: Equatable {
        let hpd: String?
        let sinkCount: Int
    }

    /// Two entries enumerate as active with nothing behind them: the placeholder macOS
    /// spawns once the last real display is gone (vendor 'unkn', model 'virt', four-character
    /// tags wider than EDID's 16 bits) and the stub a re-enabled record leaves when its
    /// hardware is gone (vendor 0, model 0, #91). A PnP vendor id packs three letters A to Z,
    /// so it is never 0; the product code can be, and a real monitor reports model 0 (#238).
    static func hasPanel(vendor: UInt32, model: UInt32) -> Bool {
        vendor != 0 && vendor <= 0xFFFF && model <= 0xFFFF
    }

    /// Entries that can be showing something. Crisp's own virtual displays do not count: a
    /// headless virtual left alone still blacks out the physical machine.
    static func viewable(_ entries: [Entry]) -> [Entry] {
        entries.filter { !$0.isCrispVirtual && hasPanel(vendor: $0.vendor, model: $0.model) }
    }

    /// Ports that can have a display behind them right now. nil, not 0, when there are no
    /// port nodes at all: the signal is unavailable, not nothing plugged in. Either hot-plug
    /// detect or a sink count is enough, since each drops out alone around a transition. An
    /// empty USB-C port keeps a CC node with neither, so it counts as present, never as
    /// asserted (#195).
    static func portCap(_ nodes: [PortNode]) -> Int? {
        guard !nodes.isEmpty else { return nil }
        return nodes.filter { $0.hpd == "High" || $0.sinkCount > 0 }.count
    }

    /// The blackout rescue's count: viewable entries with the #112 phantoms removed. After an
    /// undock while asleep, absent externals come back at wake with real EDID, so externals
    /// are capped at the live ports. When the cap is below the externals lit, an external
    /// that still has a product name (a DisplayLink display, which has no port node) is not
    /// capped. hasProductName costs 2.5 to 8 ms per display, so it is read only then. The
    /// cap never adds, and the built-in is never capped.
    static func phantomAwareCount(_ entries: [Entry], portCap: Int?, hasProductName: (UInt32) -> Bool) -> Int {
        let viewable = viewable(entries)
        let externals = viewable.filter { !$0.isBuiltin }
        var onPort = externals.count
        if let portCap, portCap < externals.count {
            onPort = externals.filter { !hasProductName($0.id) }.count
        }
        let offPort = viewable.count - onPort
        guard let portCap else { return offPort + onPort }
        return offPort + min(onPort, portCap)
    }
}
