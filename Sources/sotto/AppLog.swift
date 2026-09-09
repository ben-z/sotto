import Foundation
import OSLog

/// Written only on events. Two bounded files; no timer, retained handle, or in-memory history.
@MainActor
final class AppLog {
    static let shared = AppLog(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sotto/Logs"))
    let directory: URL
    private let limit: Int
    private let system = Logger(subsystem: "dev.sotto.app", category: "diagnostics")
    private(set) var writeFailure: String?
    var file: URL { directory.appendingPathComponent("sotto.log") }
    private var previous: URL { directory.appendingPathComponent("sotto.previous.log") }

    init(directory: URL, limit: Int = 256 * 1024) {
        self.directory = directory; self.limit = limit
    }

    func record(_ message: String, error: Bool = false) {
        // Never read Keychain to log. Redact credential-shaped text in provider errors.
        let safe = message.replacingOccurrences(of: #"(?i)gsk_[a-z0-9]+|Bearer\s+\S+"#, with: "[redacted]", options: .regularExpression)
            .components(separatedBy: .newlines).joined(separator: " ")
        let line = "\(Date().ISO8601Format()) [\(error ? "ERROR" : "INFO")] \(String(safe.prefix(1024)))\n"
        if error { system.error("\(line, privacy: .private)") }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: file.path) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if size + data.count > limit {
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    try FileManager.default.moveItem(at: file, to: previous)
                }
            }
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: file)
            do { try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close() }
            catch { try? handle.close(); throw error }
            writeFailure = nil
        } catch {
            writeFailure = "Could not write diagnostic log: \(error.localizedDescription)"
            system.error("\(self.writeFailure!, privacy: .public)")
            fputs("Sotto: \(writeFailure!)\n", stderr)
        }
    }

    func read() throws -> String {
        var text = ""
        for url in [previous, file] where FileManager.default.fileExists(atPath: url.path) {
            text += try String(contentsOf: url, encoding: .utf8)
        }
        if let writeFailure { text += "\n\(writeFailure)\n" }
        return text.isEmpty ? "No diagnostic events yet." : text
    }
}
