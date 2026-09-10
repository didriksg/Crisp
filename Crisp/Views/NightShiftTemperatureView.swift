import SwiftUI

/// One global Night Shift control, below the system effects and above Presets.
struct NightShiftTemperatureView: View {
    @ObservedObject var temperature: NightShiftTemperatureController
    @ObservedObject private var effects = CoreBrightnessService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Night Shift Temperature")
                .font(.callout)
            Slider(value: Binding(
                get: { temperature.strength ?? 0 },
                set: { value in Task { await temperature.setStrength(value) } }
            ), in: 0...1) { editing in
                temperature.setEditing(editing)
                if !editing { Task { await temperature.refresh() } }
            }
            .controlSize(.small)
            .accessibilityLabel("Night Shift Temperature")
            HStack {
                Text("Less Warm")
                Spacer()
                Text("More Warm")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .disabled(!effects.nightShiftEnabled || temperature.strength == nil)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            temperature.setEditing(false)
            Task { await temperature.refresh() }
        }
    }
}
