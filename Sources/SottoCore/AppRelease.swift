import Foundation

/// Only complete, stable releases with a downloadable app are offered.
public struct AppRelease: Decodable, Sendable {
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let state: String
        public let size: Int
    }

    public func updateURL(currentVersion: String) throws -> URL? {
        func components(_ value: String) throws -> [Int] {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
                  parts.allSatisfy({ Int($0) != nil }) else { throw SottoError("Invalid release version: \(value)") }
            return parts.map { Int($0)! }
        }
        guard !draft, !prerelease else { return nil }
        guard tag_name.hasPrefix("v") else { throw SottoError("Release tag must start with v.") }
        let version = String(tag_name.dropFirst())
        let newer = try components(currentVersion).lexicographicallyPrecedes(components(version))
        guard newer else { return nil }
        guard assets.contains(where: { $0.name == "Sotto-\(version)-macOS-universal.zip" && $0.state == "uploaded" && $0.size > 0 }) else {
            throw SottoError("Sotto \(version) is published, but its app download is not ready. Check again later.")
        }
        return URL(string: "https://github.com/ben-z/sotto/releases/tag/\(tag_name)")!
    }
}
