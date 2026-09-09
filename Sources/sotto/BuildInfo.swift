import Foundation

/// Captured at packaging time; reading this never invokes Git.
enum BuildInfo {
    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let revision = Bundle.main.object(forInfoDictionaryKey: "SottoGitRevision") as? String ?? "unpackaged"
        return "\(version) (\(revision))"
    }
    static var diagnostics: String {
        "Sotto \(version) · \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
