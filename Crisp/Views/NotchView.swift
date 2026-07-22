import SwiftUI
import AppKit

/// Displays notch information and provides a toggle to cover the notch with a black overlay.
/// Only visible for built-in displays that actually have a notch (safeAreaInsets.top > 0).
struct NotchView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isHidingNotch: Bool = false
    @State private var isHovered = false

    private func syncState() {
        isHidingNotch = NotchOverlayManager.shared.isShowingOverlay(for: display.displayID)
    }

    private var notchHeight: CGFloat {
        guard display.isBuiltin,
              let screen = NSScreen.screen(for: display.displayID)
        else { return 0 }
        return screen.safeAreaInsets.top
    }

    var body: some View {
        if notchHeight > 0 {
            VStack(alignment: .leading, spacing: 0) {
                // Info row
                HStack {
                    MenuItemIcon(systemName: "camera.aperture", color: .blue)
                    Text("Notch")
                        .font(.body)
                    Text(String(format: "%.0f pt", notchHeight))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)

                // Hide/show toggle
                HStack {
                    MenuItemIcon(systemName: isHidingNotch ? "eye.slash" : "eye", color: .gray)
                    Text("Hide Notch Area")
                        .font(.body)
                    Spacer()
                    Toggle("", isOn: $isHidingNotch)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: isHidingNotch) { _, newValue in
                            if newValue {
                                NotchOverlayManager.shared.showOverlay(for: display.displayID)
                            } else {
                                NotchOverlayManager.shared.hideOverlay(for: display.displayID)
                            }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .menuRowHover(isHovered)
                .onHover { isHovered = $0 }
            }
            .onAppear {
                syncState()
            }
        }
    }
}
