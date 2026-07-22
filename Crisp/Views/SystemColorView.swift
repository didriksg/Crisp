import SwiftUI
import AppKit

// MARK: - SystemColorViewModel

@MainActor
final class SystemColorViewModel: ObservableObject {
    @Published var sampledColor: NSColor? = nil
    @Published var hexValue: String = "--"
    @Published var rgbValue: String = "--"
    @Published var hsbValue: String = "--"
    @Published var isSampling: Bool = false

    func startSampling() {
        isSampling = true
        let sampler = NSColorSampler()
        sampler.show { [weak self] color in
            guard let self else { return }
            Task { @MainActor in
                self.isSampling = false
                guard let color = color?.usingColorSpace(.deviceRGB) else { return }
                self.sampledColor = color
                self.updateValues(from: color)
                let hex = self.colorToHex(color)
                SettingsService.shared.addColorToHistory(hex)
            }
        }
    }

    private func updateValues(from color: NSColor) {
        hexValue = colorToHex(color)
        let r = Int(color.redComponent * 255)
        let g = Int(color.greenComponent * 255)
        let b = Int(color.blueComponent * 255)
        rgbValue = "R:\(r) G:\(g) B:\(b)"
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        hsbValue = "H:\(Int(hue * 360))° S:\(Int(sat * 100))% B:\(Int(bri * 100))%"
    }

    private func colorToHex(_ color: NSColor) -> String {
        let r = Int(color.redComponent * 255)
        let g = Int(color.greenComponent * 255)
        let b = Int(color.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - SystemColorView (embedded in tools section)

struct SystemColorView: View {
    @StateObject private var vm = SystemColorViewModel()
    @ObservedObject private var settings = SettingsService.shared
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Current color display
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(vm.sampledColor.map { Color(nsColor: $0) } ?? Color.gray.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    colorValueRow(label: "HEX", value: vm.hexValue)
                    colorValueRow(label: "RGB", value: vm.rgbValue)
                    colorValueRow(label: "HSB", value: vm.hsbValue)
                }
            }
            .padding(.horizontal, 12)

            // Sample button
            Button(action: vm.startSampling) {
                HStack {
                    Image(systemName: vm.isSampling ? "eyedropper.halffull" : "eyedropper")
                    Text(vm.isSampling ? "Click anywhere on the screen to pick a color…" : "Pick Color from Screen")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 12)
            .disabled(vm.isSampling)

            // History
            if !settings.colorPickerHistory.isEmpty {
                DisclosureGroup(isExpanded: $showHistory) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 4), count: 10), spacing: 4) {
                        ForEach(settings.colorPickerHistory, id: \.self) { hex in
                            colorSwatch(hex: hex)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                } label: {
                    Text("Color History")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                }
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func colorValueRow(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
            if value != "--" {
                Button {
                    vm.copyToClipboard(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func colorSwatch(hex: String) -> some View {
        let nsColor = NSColor(hex: hex) ?? .gray
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(nsColor: nsColor))
            .frame(width: 22, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
            .onTapGesture {
                vm.copyToClipboard(hex)
            }
    }
}

// MARK: - SystemColorMenuEntry

struct SystemColorMenuEntry: View {
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            ExpandableRow(
                icon: "eyedropper.halffull",
                iconColor: .orange,
                label: "System Color",
                isExpanded: $isExpanded
            )

            if isExpanded {
                SystemColorView()
                    .padding(.leading, 8)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - NSColor hex initializer

extension NSColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6, let intVal = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((intVal >> 16) & 0xFF) / 255
        let g = CGFloat((intVal >> 8) & 0xFF) / 255
        let b = CGFloat(intVal & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
