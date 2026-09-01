import Foundation

/// Physical pixel dimensions of a display panel in its unrotated scanout space.
struct PanelResolution: Codable, Equatable, Hashable {
    let width: Int
    let height: Int

    /// Reject malformed EDID/registry values and unsafe manual input while still
    /// allowing unusual portrait and ultrawide panels.
    var isPlausible: Bool {
        guard width >= 640, height >= 480, width <= 16_384, height <= 16_384 else { return false }
        let aspect = Double(width) / Double(height)
        return aspect >= 0.25 && aspect <= 4.0
    }
}

enum PanelResolutionSource: Equatable {
    case manual
    case edid
    case registry
    case displayModes
    case currentPixels
}

struct ResolvedPanelResolution: Equatable {
    let resolution: PanelResolution
    let source: PanelResolutionSource
}

/// Accumulates native-size evidence without letting a later malformed registry
/// value erase a result that was already parsed successfully.
struct PanelResolutionEvidence {
    private(set) var edid: PanelResolution?
    private(set) var registry: PanelResolution?

    var hasResolution: Bool { edid != nil || registry != nil }

    mutating func recordEDID(_ data: Data) {
        guard let resolution = EDIDParser.preferredResolution(from: data) else { return }
        edid = resolution
    }

    mutating func recordRegistry(width: Int, height: Int) {
        let resolution = PanelResolution(width: width, height: height)
        guard resolution.isPlausible else { return }
        registry = resolution
    }
}

/// Pure precedence policy shared by DisplayInfo and headless tests.
enum PanelResolutionResolver {
    static func resolve(manual: PanelResolution?, edid: PanelResolution?,
                        registry: PanelResolution?, unscaledModes: [PanelResolution],
                        currentPixels: PanelResolution) -> ResolvedPanelResolution {
        if let manual, manual.isPlausible {
            return ResolvedPanelResolution(resolution: manual, source: .manual)
        }
        if let edid, edid.isPlausible {
            return ResolvedPanelResolution(resolution: edid, source: .edid)
        }
        if let registry, registry.isPlausible {
            return ResolvedPanelResolution(resolution: registry, source: .registry)
        }
        if let largest = unscaledModes.filter(\.isPlausible).max(by: {
            $0.width * $0.height < $1.width * $1.height
        }) {
            return ResolvedPanelResolution(resolution: largest, source: .displayModes)
        }
        return ResolvedPanelResolution(resolution: currentPixels, source: .currentPixels)
    }
}

/// Headless geometry for the BetterDisplay-style 16-point smooth-scaling grid.
enum SmoothScalingGeometry {
    static func logicalSizes(nativeWidth: Int, nativeHeight: Int,
                             minScale: Double = 0.5,
                             maximumBackingWidth: Int? = nil) -> [PanelResolution] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }
        let minWidth = Int((Double(nativeWidth) * minScale).rounded())
        var sizes: [PanelResolution] = []
        var width = nativeWidth
        while width >= minWidth {
            let height = Int((Double(width) * Double(nativeHeight) / Double(nativeWidth)).rounded())
            let resolution = PanelResolution(width: width, height: height)
            if resolution.isPlausible,
               maximumBackingWidth.map({ width * 2 <= $0 }) ?? true {
                sizes.append(resolution)
            }
            width -= 16
        }
        return sizes
    }
}

/// Keeps a virtual display's declaration list below WindowServer's practical
/// ceiling while retaining a contiguous slider window around the requested
/// looks-like size. The virtual can be rebuilt around a later request when the
/// slider moves outside this window.
enum MirrorModeGeometry {
    static func boundedStops(_ stops: [PanelResolution], including required: PanelResolution,
                             maximumCount: Int) -> [PanelResolution] {
        guard maximumCount > 0 else { return [] }

        var seen = Set<PanelResolution>()
        var unique = (stops + [required])
            .filter { seen.insert($0).inserted }
            .sorted {
                if $0.width != $1.width { return $0.width > $1.width }
                return $0.height > $1.height
            }
        guard unique.count > maximumCount else { return unique }

        let requiredIndex = unique.firstIndex(of: required) ?? unique.count - 1
        let centeredStart = max(0, requiredIndex - maximumCount / 2)
        let start = min(centeredStart, unique.count - maximumCount)
        unique = Array(unique[start..<(start + maximumCount)])
        return unique
    }
}

/// Minimal, defensive EDID parser for explicitly preferred/native timings.
/// It intentionally does not infer panel size from every advertised compatibility
/// mode: only the base preferred DTD and CTA timings carrying a native marker count.
enum EDIDParser {
    static func preferredResolution(from data: Data) -> PanelResolution? {
        let bytes = [UInt8](data)
        guard bytes.count >= 128,
              Array(bytes[0..<8]) == [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00],
              checksumIsValid(Array(bytes[0..<128])) else { return nil }

        var native: [PanelResolution] = []
        if bytes[24] & 0x02 != 0,
           let preferred = detailedTiming(bytes, at: 54) { native.append(preferred) }

        let extensionCount = min(Int(bytes[126]), bytes.count / 128 - 1)
        for index in 0..<extensionCount {
            let start = (index + 1) * 128
            let block = Array(bytes[start..<(start + 128)])
            guard checksumIsValid(block), block[0] == 0x02 else { continue }
            native.append(contentsOf: ctaNativeResolutions(block))
        }

        return native.filter(\.isPlausible).max {
            $0.width * $0.height < $1.width * $1.height
        }
    }

    private static func checksumIsValid(_ block: [UInt8]) -> Bool {
        block.count == 128 && block.reduce(0, { $0 + Int($1) }) & 0xff == 0
    }

    private static func detailedTiming(_ bytes: [UInt8], at offset: Int) -> PanelResolution? {
        guard offset >= 0, offset + 17 < bytes.count else { return nil }
        let pixelClock = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        guard pixelClock != 0 else { return nil }
        let width = Int(bytes[offset + 2]) | Int(bytes[offset + 4] & 0xf0) << 4
        let height = Int(bytes[offset + 5]) | Int(bytes[offset + 7] & 0xf0) << 4
        let result = PanelResolution(width: width, height: height)
        return result.isPlausible ? result : nil
    }

    private static func ctaNativeResolutions(_ block: [UInt8]) -> [PanelResolution] {
        let dtdOffset = block[2] == 0 ? 127 : min(Int(block[2]), 127)
        var resolutions: [PanelResolution] = []
        var cursor = 4
        while cursor < dtdOffset {
            let header = block[cursor]
            let tag = header >> 5
            let length = Int(header & 0x1f)
            guard cursor + 1 + length <= dtdOffset else { break }
            if tag == 0x02 {
                for svd in block[(cursor + 1)..<(cursor + 1 + length)] where svd & 0x80 != 0 {
                    if let resolution = resolution(forCTAVIC: svd & 0x7f) {
                        resolutions.append(resolution)
                    }
                }
            }
            cursor += 1 + length
        }

        var timingOffset = dtdOffset
        var nativeDTDCount = Int(block[3] & 0x0f)
        while nativeDTDCount > 0, timingOffset + 17 < 127 {
            if let resolution = detailedTiming(block, at: timingOffset) {
                resolutions.append(resolution)
            }
            timingOffset += 18
            nativeDTDCount -= 1
        }
        return resolutions
    }

    /// CTA-861 video identification codes whose active dimensions are relevant
    /// to panel-native inference. Multiple refresh/aspect variants share a size.
    private static func resolution(forCTAVIC vic: UInt8) -> PanelResolution? {
        switch vic {
        case 1: return PanelResolution(width: 640, height: 480)
        case 2, 3: return PanelResolution(width: 720, height: 480)
        case 4, 19, 41, 47: return PanelResolution(width: 1280, height: 720)
        case 5, 16, 20, 31...34, 39, 40, 46, 63, 64:
            return PanelResolution(width: 1920, height: 1080)
        case 17, 18: return PanelResolution(width: 720, height: 576)
        case 93...97, 103...107: return PanelResolution(width: 3840, height: 2160)
        case 98...102: return PanelResolution(width: 4096, height: 2160)
        default: return nil
        }
    }
}
