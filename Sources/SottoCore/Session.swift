import Combine
import Foundation

@MainActor
public final class Session: ObservableObject {
    public enum State: String { case idle, preparing, recording, transcribing, error }
    @Published public private(set) var state: State = .idle
    @Published public private(set) var message = "Ready"
    @Published public private(set) var lastTranscript = ""
    public var onChange: (() -> Void)?
    public var onTranscript: ((String) throws -> Void)?
    public let configuration: Configuration
    public let archive: Archive
    private let recorder = Recorder()
    private var record: RecordingRecord?
    private var upload: Task<TranscriptionResult, Error>?
    private var deadline: Task<Void, Never>?
    private var stopWhilePreparing = false

    public init(configuration: Configuration) throws {
        try configuration.validate()
        self.configuration = configuration
        archive = try Archive(directory: configuration.recordingsURL)
        recorder.onUnexpectedStop = { [weak self] error in
            guard let self, self.state == .recording else { return }
            Task { await self.finish(recordingError: error) }
        }
    }

    private func change(_ state: State, _ message: String) {
        self.state = state; self.message = message; onChange?()
    }

    public func fail(_ error: Error) { change(.error, error.localizedDescription) }

    public func begin(contextTerms: [String] = []) async {
        guard state == .idle || state == .error else { return }
        stopWhilePreparing = false
        record = nil
        change(.preparing, "Preparing microphone")
        do {
            _ = try GroqKeychain.read() // Fail before recording when credentials are missing.
            guard await Recorder.requestPermission() else { throw SottoError("Microphone permission denied. Enable Sotto in System Settings > Privacy & Security > Microphone.") }
            guard !stopWhilePreparing else { change(.idle, "Cancelled before recording"); return }
            let history = try archive.recentContext(limit: configuration.contextHistoryCount)
            let prompt = Prompt.build(contextTerms: contextTerms + history)
            let newRecord = try archive.newRecord(model: configuration.model, language: configuration.language, prompt: prompt, contextTerms: contextTerms)
            record = newRecord
            try recorder.start(at: archive.audioURL(newRecord), bitRate: configuration.audioBitRate)
            change(.recording, "Recording · \(newRecord.id)")
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(self?.configuration.maxRecordingSeconds ?? 1800)) }
                catch { return }
                await self?.finish()
            }
        } catch {
            if var record {
                record.status = "failed"; record.error = error.localizedDescription
                do { try archive.save(record) } catch { fail(error); return }
            }
            fail(error)
        }
    }

    public func finish(recordingError: String? = nil) async {
        if state == .preparing { stopWhilePreparing = true; return }
        guard state == .recording, var record else { return }
        deadline?.cancel(); deadline = nil
        change(.transcribing, "Transcribing · \(record.id)")
        do {
            record.durationSeconds = try recorder.stop()
            record.audioBytes = try archive.audioURL(record).resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let recordingError { throw SottoError(recordingError) }
            record.status = "transcribing"
            try archive.save(record)
            let key = try GroqKeychain.read()
            let file = archive.audioURL(record)
            let model = record.model, language = record.language, prompt = record.prompt
            let trimWhitespace = configuration.trimWhitespace
            let task = Task { try await GroqClient().transcribe(file: file, key: key, model: model, language: language, prompt: prompt, trimWhitespace: trimWhitespace) }
            upload = task
            let result = try await task.value
            try Task.checkCancellation()
            guard !task.isCancelled else { throw CancellationError() }
            try archive.complete(&record, with: result)
            lastTranscript = result.text
            // Files are safely persisted before clipboard/paste delivery.
            do { try onTranscript?(result.text) }
            catch {
                record.error = "Transcript saved; delivery failed: \(error.localizedDescription)"
                try archive.save(record)
                throw SottoError(record.error!)
            }
            change(.idle, "Saved · \(record.id) · \(result.milliseconds) ms")
        } catch {
            if record.status != "complete" { record.status = upload?.isCancelled == true ? "cancelled" : "failed" }
            record.error = error.localizedDescription
            do { try archive.save(record); fail(error) }
            catch { fail(SottoError("Could not save failure metadata: \(error.localizedDescription). Audio remains at \(archive.audioURL(record).path).")) }
        }
        upload = nil; self.record = nil
    }

    public func cancel() async {
        if state == .preparing { stopWhilePreparing = true; return }
        if state == .transcribing { upload?.cancel(); return }
        guard state == .recording, var record else { return }
        deadline?.cancel(); deadline = nil
        do {
            record.durationSeconds = try recorder.stop()
            record.status = "cancelled"
            record.audioBytes = try archive.audioURL(record).resourceValues(forKeys: [.fileSizeKey]).fileSize
            try archive.save(record)
            self.record = nil
            change(.idle, "Cancelled; audio retained · \(record.id)")
        } catch { fail(error) }
    }
}
