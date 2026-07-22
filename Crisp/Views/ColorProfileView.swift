import SwiftUI

/// Color profile selection as a native dropdown menu (NSPopUpButton-backed),
/// exactly like the profile menu in the system Displays panel: opens instantly,
/// checkmark on the active profile.
struct ColorProfileView: View {
    @ObservedObject var display: DisplayInfo
    @State private var profiles: [ICCProfile] = []
    @State private var isLoading: Bool = false
    @State private var selectedPath: URL?
    @State private var applyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Profile")
                    .font(.body)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Picker("", selection: $selectedPath) {
                        if !recommendedProfiles.isEmpty {
                            Section("Recommended") {
                                ForEach(recommendedProfiles) { profile in
                                    Text(profile.name).tag(Optional(profile.path))
                                }
                            }
                        }
                        if !otherProfiles.isEmpty {
                            Section("All Profiles") {
                                ForEach(otherProfiles) { profile in
                                    Text(profile.name).tag(Optional(profile.path))
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                    .onChange(of: selectedPath) { oldValue, newValue in
                        guard let url = newValue, oldValue != newValue,
                              let profile = profiles.first(where: { $0.path == url }) else { return }
                        applyProfile(profile, revertTo: oldValue)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            if let error = applyError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .task { await loadProfiles() }
    }

    // MARK: - Grouping

    private var recommendedProfiles: [ICCProfile] {
        let keywords = ["sRGB", "P3", "Display", "LCD", "Apple", "Color LCD"]
        return profiles.filter { p in
            keywords.contains { p.name.localizedCaseInsensitiveContains($0) }
        }
    }

    private var otherProfiles: [ICCProfile] {
        let recommended = Set(recommendedProfiles.map(\.path))
        return profiles.filter { !recommended.contains($0.path) }
    }

    // MARK: - Actions

    @MainActor
    private func loadProfiles() async {
        isLoading = true
        let displayID = display.displayID
        let svc = ColorProfileService.shared
        let loaded = await svc.enumerateProfiles()
        let currentURL = svc.currentProfileURL(for: displayID)
        profiles = loaded
        // Snap to the enumerated entry by file path: the device registry URL
        // and FileManager's can differ in percent-encoding, and the Picker
        // shows an empty selection unless the tag matches exactly.
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
            applyError = "Failed to apply. Please try again."
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                applyError = nil
            }
        }
    }
}
