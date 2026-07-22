import SwiftUI

/// "Auto Brightness" section — follows builtin screen brightness and adjusts external display brightness automatically.
struct AutoBrightnessView: View {
    @StateObject private var service = AutoBrightnessService.shared
    @State private var isHovered = false

    /// True only after the service has polled at least once and found no builtin display.
    private var builtinUnavailable: Bool {
        service.hasPolled && service.builtinBrightness <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main toggle
            HStack {
                MenuItemIcon(systemName: "sun.and.horizon.fill", color: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Brightness")
                        .font(.body)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $service.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(builtinUnavailable)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .menuRowHover(isHovered)
            .onHover { isHovered = $0 }
            .contentShape(Rectangle())
        }
    }

    private var statusText: String {
        if builtinUnavailable {
            return "No built-in display detected"
        } else if service.isEnabled {
            return "Syncing with built-in display brightness"
        } else {
            return "Adjusts external displays to follow the built-in display brightness"
        }
    }
}
