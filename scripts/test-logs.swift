import Foundation

@main
struct LogTests {
    @MainActor static func main() {
        let safe = AppLog.sanitized("failed\nBearer secret-token gsk_secret123")
        precondition(safe == "failed [redacted] [redacted]")
        precondition(AppLog.sanitized(String(repeating: "x", count: 2000)).count == 1024)
        precondition(AppLog.sanitized("ordinary diagnostic") == "ordinary diagnostic")
        print("Diagnostic redaction and message bounds passed")
    }
}
