import Foundation
import OSLog

/// macOS owns persistence and retention; Sotto keeps no separate log files.
@MainActor
final class AppLog {
    static let shared = AppLog()
    private let system = Logger(subsystem: "dev.sotto.app", category: "diagnostics")

    static func sanitized(_ message: String) -> String {
        let safe = message.replacingOccurrences(of: #"(?i)gsk_[a-z0-9]+|Bearer\s+\S+"#, with: "[redacted]", options: .regularExpression)
            .components(separatedBy: .newlines).joined(separator: " ")
        return String(safe.prefix(1024))
    }

    func record(_ message: String, error: Bool = false) {
        let safe = Self.sanitized(message)
        if error { system.error("\(safe, privacy: .public)") }
        else { system.notice("\(safe, privacy: .public)") }
    }
}
