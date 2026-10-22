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
@MainActor private func checkCancellationWriteFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try Session(configuration: Configuration(recordingsDirectory: root.path))
    await session.begin()
    guard session.state == .recording, let id = session.activeRecordingID else {
        throw SottoError("The cancellation fixture did not start recording")
    }
    let metadata = root.appendingPathComponent("\(id).json")
    let original = try Data(contentsOf: metadata)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
    await session.cancel()
    guard session.state == .error, session.activeRecordingID == nil, session.retainedRecordingID == id else {
        throw SottoError("A stopped recording remained active after its cancelled status could not be saved")
    }
    guard try Data(contentsOf: metadata) == original,
          try Data(contentsOf: root.appendingPathComponent("\(id).m4a")) == Data([1]) else {
        throw SottoError("Cancellation write failure changed the retained recording")
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
        try await checkCancellationWriteFailure()
        let transcripts = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
        guard transcripts.count == 1,
              try String(contentsOf: transcripts[0], encoding: .utf8) == "Deadline transcript" else {
            throw SottoError("Automatic stop did not persist the successful transcription")
        }
        print("Session deadline and transcript persistence checks passed.")
    }
}
