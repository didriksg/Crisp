import SwiftUI

/// Color profile selection as a native checkmarked list (same style as the
/// resolution and preset lists): a flat list scoped to this display, like
/// macOS's display color dropdown; checkmark on the active profile.
struct ColorProfileView: View {
    @ObservedObject var display: DisplayInfo
    /// The parent row's subtitle; updated here so it refreshes immediately on switch.
    @Binding var activeProfileName: String
    @State private var profiles: [ICCProfile] = []
    @State private var isLoading: Bool = false
    @State private var selectedPath: URL?
    @State private var applyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Text("Loading profiles…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 24)
                .padding(.vertical, 6)
            } else {
                ForEach(profiles) { profile in
                    CheckmarkRow(label: profile.name, isSelected: profile.path == selectedPath) {
                        select(profile)
                    }
                }
            }

            if let error = applyError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 24)
                    .padding(.bottom, 4)
            }
        }
        .task { await loadProfiles() }
        // HDR mode switches (and System Settings) change the active profile
        // while this list is expanded; re-snap the checkmark. Debounced
        // because mode switches emit bursts of reconfigurations.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
        ) { _ in
            Task { await loadProfiles() }
        }
    }

    // MARK: - Actions

    private func select(_ profile: ICCProfile) {
        guard profile.path != selectedPath else { return }
        let previous = selectedPath
        selectedPath = profile.path
        applyProfile(profile, revertTo: previous)
    }

    @MainActor
    private func loadProfiles() async {
        // Spinner only on first load; silent re-snap when refreshing an
        // already-populated list (screen reconfiguration).
        isLoading = profiles.isEmpty
        let displayID = display.displayID
        let displayUUID = display.displayUUID
        let svc = ColorProfileService.shared
        let loaded = await svc.enumerateProfiles(for: displayUUID)
        let currentURL = svc.currentProfileURL(for: displayID)
        profiles = loaded
        // Snap to the enumerated entry by file path: the device registry URL
        // and FileManager's can differ in percent-encoding, and the selection
        // shows as unset unless the path matches exactly.
        if let cur = currentURL,
           let match = loaded.first(where: { $0.path.path == cur.path }) {
            selectedPath = match.path
        } else {
            selectedPath = currentURL
        }
        isLoading = false
    }

    @MainActor
    private func applyProfile(_ profile: ICCProfile, revertTo previous: URL?) {
        applyError = nil
        let success = ColorProfileService.shared.setProfile(profile, for: display.displayID)
        if !success {
            selectedPath = previous
            applyError = String(localized: "Failed to apply. Please try again.")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                applyError = nil
            }
        } else if activeProfileName != profile.name {
            activeProfileName = profile.name
        }
    }
}
