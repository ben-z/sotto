import Foundation

// Compile with the production Session, Archive, and Configuration. Only device
// and service dependencies are fixtures, so the real deadline and save path run.
@MainActor final class Recorder {
    var onUnexpectedStop: ((String?) -> Void)?
    static func requestPermission() async -> Bool { true }
    func start(at url: URL, bitRate: Int) throws { try Data([1]).write(to: url) }
    func stop() throws -> Double { 1 }
}
enum GroqKeychain { static func read() throws -> String { "fixture" } }
public struct TranscriptionResult: Sendable {
    let text: String
    let rawResponse: Data
    let milliseconds: Int
    let requestID: String?
}
struct GroqClient {
    func transcribe(file: URL, key: String, model: String, language: String?, prompt: String, trimWhitespace: Bool) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        return TranscriptionResult(text: "Deadline transcript", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
    }
}
@main struct SessionTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = Configuration(recordingsDirectory: root.path)
        configuration.maxRecordingSeconds = 1
        let session = try Session(configuration: configuration)
        var delivered = ""
        session.onTranscript = { delivered = $0 }
        await session.begin()
        try await Task.sleep(for: .seconds(2))
        guard session.state == .idle, session.lastTranscript == "Deadline transcript", delivered == "Deadline transcript" else {
            throw SottoError("Automatic stop discarded a successful transcription")
        }
        let transcripts = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
        guard transcripts.count == 1,
              try String(contentsOf: transcripts[0], encoding: .utf8) == "Deadline transcript" else {
            throw SottoError("Automatic stop did not persist the successful transcription")
        }
        print("Session deadline and transcript persistence checks passed.")
    }
}
