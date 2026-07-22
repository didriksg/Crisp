import SwiftUI

/// Reference-mode preset picker, mirroring the System Settings "Preset" menu
/// for displays that have presets (XDR builtin panels).
struct DisplayPresetView: View {
    let displayID: CGDirectDisplayID
    /// The parent row's subtitle; updated here so it refreshes on switch.
    @Binding var activeName: String
    @State private var presets: [DisplayPresetService.Preset] = []
    @State private var selectedIndex: Int?

    var body: some View {
        HStack {
            Text("Preset")
                .font(.body)
            Spacer()
            Picker("", selection: $selectedIndex) {
                ForEach(presets) { preset in
                    Text(preset.name).tag(Optional(preset.index))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 220)
            .onChange(of: selectedIndex) { oldValue, newValue in
                guard let index = newValue, oldValue != nil, oldValue != newValue else { return }
                if DisplayPresetService.shared.setActivePreset(index: index, for: displayID),
                   let name = presets.first(where: { $0.index == index })?.name {
                    activeName = name
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onAppear {
            presets = DisplayPresetService.shared.presets(for: displayID)
            selectedIndex = DisplayPresetService.shared.activePresetIndex(for: displayID)
        }
    }
}
