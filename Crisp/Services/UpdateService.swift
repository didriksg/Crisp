import Foundation
import AppKit

/// Checks for new releases on GitHub and surfaces the latest version info.
@MainActor
final class UpdateService: ObservableObject, @unchecked Sendable {
    static let shared = UpdateService()

    // Set these when the repo is published. Placeholder values disable the update check.
    private let repoOwner = "OWNER"
    private let repoName  = "FreeDisplay"

    // Current app bundle version (CFBundleShortVersionString)
    let currentVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()

    @Published var latestVersion: String? = nil
    @Published var releaseURL: URL? = nil
    @Published var isChecking: Bool = false
    @Published var hasUpdate: Bool = false
    @Published var lastCheckDate: Date? = nil

    private init() {}

    // MARK: - Check for Updates

    func checkForUpdates() async {
        guard !repoOwner.isEmpty, repoOwner != "OWNER", !repoName.isEmpty else {
            // Repo not yet configured — silently skip update check
            return
        }
        if let last = lastCheckDate, Date().timeIntervalSince(last) < 3600 { return }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                // Repo may not exist yet; silently ignore
                lastCheckDate = Date()
                return
            }
            let json: [String: Any]?
            do {
                json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } catch {
                #if DEBUG
                print("[UpdateService] JSON parse error: \(error)")
                #endif
                lastCheckDate = Date()
                return
            }
            if let tag = json?["tag_name"] as? String {
                let clean = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                latestVersion = clean
                releaseURL = (json?["html_url"] as? String).flatMap { URL(string: $0) }
                hasUpdate = isNewerVersion(clean, than: currentVersion)
            }
            lastCheckDate = Date()
        } catch {
            // Network unavailable or repo doesn't exist — silently ignore
            lastCheckDate = Date()
        }
    }

    // MARK: - Version Comparison

    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let remoteComponents = remote.split(separator: ".").compactMap { Int($0) }
        let localComponents  = local.split(separator: ".").compactMap { Int($0) }
        let length = max(remoteComponents.count, localComponents.count)
        for i in 0..<length {
            let r = i < remoteComponents.count ? remoteComponents[i] : 0
            let l = i < localComponents.count  ? localComponents[i]  : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    // MARK: - Open Release Page

    func openReleasePage() {
        guard let url = releaseURL else { return }
        NSWorkspace.shared.open(url)
    }
}
