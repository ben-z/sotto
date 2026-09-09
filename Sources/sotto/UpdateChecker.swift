import AppKit
import SottoCore

/// One request at launch and daily. No updater framework, disk cache, or installer.
@MainActor
final class UpdateChecker: NSObject {
    let checkItem = NSMenuItem(title: "Check for Updates", action: nil, keyEquivalent: "")
    let statusItem = NSMenuItem(title: "Updates not checked", action: nil, keyEquivalent: "")
    let downloadItem = NSMenuItem(title: "Download Update…", action: nil, keyEquivalent: "")
    private var releaseURL: URL?
    private var request: Task<Void, Never>?
    private var schedule: Task<Void, Never>?
    private var automatic: Bool?
    private let version: String?
    private let fetch: @Sendable (String) async throws -> AppRelease

    init(version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         fetch: @escaping @Sendable (String) async throws -> AppRelease = UpdateChecker.fetchLatest) {
        self.version = version; self.fetch = fetch
        super.init()
        checkItem.target = self; checkItem.action = #selector(check)
        statusItem.isEnabled = false
        downloadItem.target = self; downloadItem.action = #selector(download)
        downloadItem.isHidden = true
    }

    func configure(automatic enabled: Bool) {
        guard enabled != automatic else { return }
        automatic = enabled
        schedule?.cancel(); schedule = nil
        if enabled {
            check()
            schedule = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(86_400)) } catch { return }
                    self?.check()
                }
            }
        } else {
            request?.cancel(); request = nil
            checkItem.isEnabled = true
            statusItem.title = "Automatic update checks off"
        }
    }

    @objc func check() {
        guard request == nil else { return }
        checkItem.isEnabled = false
        statusItem.title = "Checking for updates…"
        statusItem.toolTip = nil
        request = Task { [weak self] in
            guard let self else { return }
            defer {
                // A cancelled request must not clear a newer request after re-enabling.
                if !Task.isCancelled { request = nil; checkItem.isEnabled = true }
            }
            do {
                try Task.checkCancellation()
                guard let version else {
                    throw SottoError("Update checking requires a packaged Sotto app with a version.")
                }
                let release = try await fetch(version)
                try Task.checkCancellation()
                releaseURL = try release.updateURL(currentVersion: version)
                downloadItem.isHidden = releaseURL == nil
                downloadItem.title = "Download Sotto \(release.tag_name)…"
                statusItem.title = releaseURL == nil ? "Sotto is up to date · checked \(Date().formatted(date: .omitted, time: .shortened))" : "Sotto \(release.tag_name) is available"
                AppLog.shared.record("Updates: \(statusItem.title)")
            } catch {
                guard !Task.isCancelled else { return }
                statusItem.title = "Couldn’t check for updates · try again"
                statusItem.toolTip = error.localizedDescription
                AppLog.shared.record("Update check: \(error.localizedDescription)", error: true)
            }
        }
    }

    nonisolated static func fetchLatest(version: String) async throws -> AppRelease {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        var query = URLRequest(url: URL(string: "https://api.github.com/repos/ben-z/sotto/releases/latest")!)
        query.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        query.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        query.setValue("Sotto/\(version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await client.data(for: query)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SottoError("Update check failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Try again later.")
        }
        return try JSONDecoder().decode(AppRelease.self, from: data)
    }

    @objc private func download() {
        guard let releaseURL else { return }
        if !NSWorkspace.shared.open(releaseURL) {
            statusItem.title = "Couldn’t open the release page"
            AppLog.shared.record("Could not open \(releaseURL.absoluteString)", error: true)
        }
    }
}
