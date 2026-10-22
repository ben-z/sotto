import Foundation

// Compile with the production Session, Archive, and Configuration. Only device
// and service dependencies are fixtures, so the real deadline and save path run.
@MainActor final class Recorder {
    static weak var latest: Recorder?
    var onUnexpectedStop: ((String?) -> Void)?
    init() { Self.latest = self }
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
        try await currentRecorderCallbackFinishesRecording(in: root)
        try await delayedCallbackPreservesReplacementRecording(in: root)
        print("Session deadline, callback ownership, and transcript persistence checks passed.")
    }

    @MainActor private static func currentRecorderCallbackFinishesRecording(in root: URL) async throws {
        var id = ""
        weak var pending: Session?
        do {
            let session = try Session(configuration: Configuration(recordingsDirectory: root.path))
            pending = session
            await session.begin()
            guard session.state == .recording, let recordingID = session.activeRecordingID,
                  let notify = Recorder.latest?.onUnexpectedStop else {
                throw SottoError("Recorder callback fixture did not begin recording")
            }
            id = recordingID
            notify(nil)
        }
        while pending != nil { await Task.yield() }
        guard try String(contentsOf: root.appendingPathComponent("\(id).txt"), encoding: .utf8) == "Deadline transcript" else {
            throw SottoError("The current recorder's completion callback did not save its transcription")
        }
    }

    @MainActor private static func delayedCallbackPreservesReplacementRecording(in root: URL) async throws {
        var replacementID = ""
        weak var pending: Session?
        do {
            let session = try Session(configuration: Configuration(recordingsDirectory: root.path))
            pending = session
            await session.begin()
            guard session.state == .recording, let originalID = session.activeRecordingID,
                  let notify = Recorder.latest?.onUnexpectedStop else {
                throw SottoError("Recorder callback fixture did not begin recording")
            }
            notify("Delayed encoder failure")
            // These same-actor fixture calls do not suspend, so the queued callback runs later.
            await session.cancel()
            await session.begin()
            guard session.state == .recording, let recordingID = session.activeRecordingID, recordingID != originalID else {
                throw SottoError("Recorder callback fixture did not replace the recording")
            }
            replacementID = recordingID
        }
        // The callback task retains the session until it has checked recording ownership.
        while pending != nil { await Task.yield() }
        let data = try Data(contentsOf: root.appendingPathComponent("\(replacementID).json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let replacement = try decoder.decode(RecordingRecord.self, from: data)
        guard replacement.status == "recording", replacement.error == nil else {
            throw SottoError("An earlier recorder's delayed callback changed the replacement recording")
        }
    }
}
