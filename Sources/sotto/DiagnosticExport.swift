import Foundation
import SottoCore

/// An on-demand system query, streamed to disk rather than buffered in memory.
enum DiagnosticExport {
    static let arguments = ["show", "--last", "1d", "--style", "compact", "--predicate", "subsystem == \"dev.sotto.app\" AND process == \"sotto\""]
    static let command = "/usr/bin/log show --last 1d --style compact --predicate 'subsystem == \"dev.sotto.app\" AND process == \"sotto\"'"

    static func save(to destination: URL) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let header = "\(BuildInfo.diagnostics)\nExported: \(Date().ISO8601Format())\nLast 24 hours · macOS controls retention; some events may have expired.\n\n"
        try Data(header.utf8).write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try output.seekToEnd()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: SottoError("macOS log export failed (exit \(process.terminationStatus)). Try the terminal command for details.")) }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        try output.synchronize()
        try Data(contentsOf: temporary, options: .mappedIfSafe).write(to: destination, options: .atomic)
    }
}
