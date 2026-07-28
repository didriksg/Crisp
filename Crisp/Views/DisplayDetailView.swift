import SwiftUI

// MARK: - DisplayDetailView

struct DisplayDetailView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @State private var showModeList: Bool = false
    @State private var showPreset: Bool = false
    @State private var showColorProfile: Bool = false
    @State private var showImageAdjustment: Bool = false
    @State private var colorSpaceName: String = ""
    @State private var presetName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Brightness slider is inline at the top level (avoid duplication); HiDPI toggle moved to Settings

            // Display mode list toggle row
            ExpandableRow(
                icon: "rectangle.on.rectangle",
                label: "Display Mode",
                subtitle: {
                    var parts: [String] = []
                    if let mode = display.currentDisplayMode {
                        parts.append(mode.resolutionString)
                    }
                    if display.currentDisplayMode?.isHiDPI == true {
                        parts.append("HiDPI")
                    }
                    return parts.joined(separator: " · ")
                }(),
                isExpanded: $showModeList
            )

            VStack(spacing: 0) {
                if showModeList {
                    DisplayModeListView(display: display)
                        .padding(.leading, 8)
                        .transition(.opacity)
                }
            }
            .clipped()

            SectionDivider()

            // Reference preset section (XDR builtin panels), mirrors the
            // System Settings "Preset" menu
            if !presetName.isEmpty {
                ExpandableRow(
                    icon: "camera.filters",
                    iconColor: .indigo,
                    label: "Preset",
                    subtitle: presetName,
                    isExpanded: $showPreset
                )

                VStack(spacing: 0) {
                    if showPreset {
                        DisplayPresetView(displayID: display.displayID, activeName: $presetName)
                            .padding(.leading, 8)
                            .transition(.opacity)
                    }
                }
                .clipped()
            }

            // Color profile section; hidden when the display has presets,
            // matching System Settings (XDR panels get Preset instead)
            if presetName.isEmpty {
                ExpandableRow(
                    icon: "paintpalette.fill",
                    iconColor: .purple,
                    label: "Color Profile",
                    subtitle: colorSpaceName,
                    isExpanded: $showColorProfile
                )

                VStack(spacing: 0) {
                    if showColorProfile {
                        ColorProfileView(display: display)
                            .padding(.leading, 8)
                            .transition(.opacity)
                    }
                }
                .clipped()
            }

            // Image adjustment section
            ExpandableRow(
                icon: "slider.horizontal.3",
                label: "Image Adjustment",
                isExpanded: $showImageAdjustment
            )

            VStack(spacing: 0) {
                if showImageAdjustment {
                    ImageAdjustmentView(display: display)
                        .padding(.leading, 8)
                        .transition(.opacity)
                }
            }
            .clipped()

            SectionDivider()

            // Set as main display
            MainDisplayView(display: display)

            // Disconnect this physical display (Apple Silicon only; hidden for the last screen)
            DisconnectDisplayRow(display: display)

            // Notch management (built-in with notch only)
            NotchView(display: display)

        }
        .padding(8)
        // Card background matching SavePresetForm: rounded rect with a thin
        // border stroke so the expanded display detail reads as a bounded
        // card (same idiom as the "New Preset" form), not a full-width band.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            // Reopen fresh, like a native menu (this view persists across opens, so
            // its sections stay expanded until reset).
            showModeList = false
            showPreset = false
            showColorProfile = false
            showImageAdjustment = false
        }
        .task(id: display.displayID) {
            colorSpaceName = ""
            presetName = ""
            guard !Task.isCancelled else { return }
            colorSpaceName = ColorProfileService.shared.currentColorSpaceName(for: display.displayID)
            let svc = DisplayPresetService.shared
            if let idx = svc.activePresetIndex(for: display.displayID) {
                presetName = svc.presets(for: display.displayID)
                    .first(where: { $0.index == idx })?.name ?? ""
            }
        }
    }
}

