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

    private func sectionKey(_ name: String) -> String {
        "fd.expanded.\(display.displayUUID).\(name)"
    }

    private func loadExpanded(_ name: String, default value: Bool) -> Bool {
        let key = sectionKey(name)
        guard UserDefaults.standard.object(forKey: key) != nil else { return value }
        return UserDefaults.standard.bool(forKey: key)
    }

    private func saveExpanded(_ name: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: sectionKey(name))
    }

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

            Divider().opacity(0.3).padding(.vertical, 2)

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

            Divider().opacity(0.3).padding(.vertical, 2)

            // Set as main display
            MainDisplayView(display: display)

            // Notch management (built-in with notch only)
            NotchView(display: display)

        }
        .padding(.leading, 32)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .onAppear {
            showModeList = loadExpanded("modeList", default: false)
            showPreset = loadExpanded("preset", default: false)
            showColorProfile = loadExpanded("colorProfile", default: false)
            showImageAdjustment = loadExpanded("imageAdjust", default: false)
        }
        .onChange(of: showModeList) { _, v in saveExpanded("modeList", v) }
        .onChange(of: showPreset) { _, v in saveExpanded("preset", v) }
        .onChange(of: showColorProfile) { _, v in saveExpanded("colorProfile", v) }
        .onChange(of: showImageAdjustment) { _, v in saveExpanded("imageAdjust", v) }
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

