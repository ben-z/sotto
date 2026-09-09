import Foundation

@main
struct LogTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = AppLog(directory: root.appendingPathComponent("logs"), limit: 8192)
        log.record("failed\nBearer secret-token gsk_secret123", error: true)
        let initial = try log.read()
        precondition(initial.contains("[ERROR] failed [redacted] [redacted]"))
        precondition(!initial.contains("secret"))
        precondition(initial.split(separator: "\n").count == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: log.file.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        for i in 0..<100 { log.record("event-\(i) " + String(repeating: "x", count: 300)) }
        precondition(log.writeFailure == nil)
        let files = try FileManager.default.contentsOfDirectory(at: log.directory, includingPropertiesForKeys: [.fileSizeKey])
        precondition(files.count == 2)
        for file in files {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            precondition(size <= 8192)
        }
        let reopened = AppLog(directory: log.directory)
        let history = try reopened.read()
        precondition(history.contains("event-99"))
        precondition(!history.contains("event-0 "))
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failed = AppLog(directory: blocked)
        failed.record("expected write failure")
        precondition(failed.writeFailure != nil)
        let failure = try failed.read()
        precondition(failure.contains("Could not write diagnostic log"))
        print("Log persistence, rotation, redaction, permissions, and write-failure checks passed")
    }
}
