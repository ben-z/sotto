import Foundation
import Combine
import OSLog

/// Each audio file and its metadata are the durable queue. No database or worker service.
@MainActor
public final class NoteLibrary: ObservableObject {
    @Published public private(set) var notes: [RecordingRecord] = []
    @Published public private(set) var transcribingID: String?
    @Published public private(set) var issue: String?
    public let archive: Archive
    private let log = Logger(subsystem: "dev.sotto.notes", category: "queue")

    public init(directory: URL) throws {
        archive = try Archive(directory: directory)
        try reload(recover: true)
    }

    public func reload(recover: Bool = false) throws {
        let files = try FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil)
        var records: [RecordingRecord] = []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".response.json") {
            var note: RecordingRecord
            do { note = try decoder.decode(RecordingRecord.self, from: Data(contentsOf: url)) }
            catch { throw SottoError("Cannot read \(url.lastPathComponent): \(error.localizedDescription)") }
            guard note.id == url.deletingPathExtension().lastPathComponent,
                  note.audioFile == "\(note.id).m4a" else { throw SottoError("Invalid note metadata in \(url.lastPathComponent)") }
            if recover && note.status == "transcribing" { note.status = "queued"; try archive.save(note) }
            if recover && note.status == "recording" {
                note.status = "interrupted"
                note.error = "Recording was interrupted. The retained audio may be incomplete."
                try archive.save(note)
            }
            if note.generatedTitle == nil && note.status == "complete" {
                let transcript = archive.directory.appendingPathComponent("\(note.id).txt")
                if FileManager.default.fileExists(atPath: transcript.path) {
                    note.generatedTitle = RecordingRecord.suggestedTitle(from: try String(contentsOf: transcript, encoding: .utf8))
                }
            }
            records.append(note)
        }
        notes = records.sorted { $0.startedAt > $1.startedAt }
    }

    public func create(model: String, language: String?) throws -> RecordingRecord {
        let note = try archive.newRecord(model: model, language: language, prompt: "", contextTerms: [])
        try reload()
        return note
    }

    public func save(_ note: RecordingRecord) throws {
        try archive.save(note)
        log.notice("Note \(note.id, privacy: .public): \(note.status, privacy: .public)")
        try reload()
    }

    public func queue(_ note: RecordingRecord, duration: Double? = nil) throws {
        var note = notes.first { $0.id == note.id } ?? note
        let size = try archive.audioURL(note).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw SottoError("This note has no playable audio. Its metadata has been retained.") }
        note.status = "queued"; note.error = nil; note.audioBytes = size
        if let duration { note.durationSeconds = duration }
        try save(note)
    }

    public func finishRecording(_ note: RecordingRecord, recordingError: String?, stop: () throws -> Double) throws {
        do {
            let duration = try stop()
            if let recordingError { throw SottoError(recordingError) }
            try queue(note, duration: duration)
        } catch {
            let message = error.localizedDescription
            do { try interrupt(note.id, message: message) }
            catch { throw SottoError("\(message) · Could not save interrupted status: \(error.localizedDescription)") }
            throw error
        }
    }

    private func interrupt(_ id: String, message: String) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw SottoError("The interrupted recording is no longer available.")
        }
        // A stopped recorder must remain editable even if storage rejects the status write.
        notes[index].status = "interrupted"
        notes[index].error = message
        try archive.save(notes[index])
    }

    public func transcribe(_ ids: Set<String>, model: String, language: String?) throws {
        let selected = try editableNotes(ids)
        // Validate the whole selection before changing its queue state.
        for note in selected {
            let size = try archive.audioURL(note).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw SottoError("\(note.displayTitle) has no audio to transcribe.") }
        }
        for var note in selected {
            if note.transcribedModel == nil && note.status == "complete" { note.transcribedModel = note.model }
            note.model = model; note.language = language
            note.status = "queued"; note.error = nil
            try save(note)
        }
    }

    private func editableNotes(_ ids: Set<String>) throws -> [RecordingRecord] {
        let selected = notes.filter { ids.contains($0.id) }
        guard selected.count == ids.count else { throw SottoError("Some selected notes are no longer available.") }
        guard !selected.contains(where: { $0.status == "recording" || $0.id == transcribingID || $0.status == "transcribing" }) else {
            throw SottoError("Wait for recording or transcription to finish before changing these notes.")
        }
        return selected
    }

    public func delete(_ ids: Set<String>) throws {
        let selected = try editableNotes(ids)
        for note in selected {
            // Metadata goes last so a failed removal remains visible and can be retried.
            for ext in ["m4a", "txt", "md", "response.json", "json"] {
                let url = archive.directory.appendingPathComponent("\(note.id).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            notes.removeAll { $0.id == note.id }
        }
    }

    public func text(for note: RecordingRecord) throws -> String {
        for ext in ["md", "txt"] {
            let url = archive.directory.appendingPathComponent("\(note.id).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return try String(contentsOf: url, encoding: .utf8) }
        }
        return ""
    }

    public func saveText(_ text: String, for note: RecordingRecord) throws {
        // Keep the machine transcript and raw response when a person edits their note.
        try text.write(to: archive.directory.appendingPathComponent("\(note.id).md"), atomically: true, encoding: .utf8)
        objectWillChange.send()
    }

    public func rename(_ note: RecordingRecord, to title: String) throws {
        var note = notes.first { $0.id == note.id } ?? note
        note.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(note)
    }

    /// Sequential uploads; interrupted/offline work remains queued for the next opportunity.
    public func process(key: () throws -> String,
                        transcribe: (URL, String, RecordingRecord) async throws -> TranscriptionResult) async {
        guard transcribingID == nil else { return }
        issue = nil
        while let candidate = notes.reversed().first(where: { $0.status == "queued" }) {
            if Task.isCancelled { return }
            var note = candidate
            var completed = false
            do {
                let secret = try key()
                note.status = "transcribing"; note.error = nil
                try save(note)
                transcribingID = note.id
                let result = try await transcribe(archive.audioURL(note), secret, note)
                // Persist a returned result even if cancellation arrived with it.
                // Preserve metadata edits made while the upload was running.
                note = notes.first { $0.id == candidate.id } ?? note
                try archive.complete(&note, with: result)
                completed = true
                log.notice("Note \(note.id, privacy: .public): complete")
                try reload()
            } catch {
                if completed {
                    issue = "Transcription was saved, but the note list could not refresh: \(error.localizedDescription)"
                    transcribingID = nil
                    return
                }
                let offline = (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost].contains($0.code) } ?? false
                note = notes.first { $0.id == candidate.id } ?? note
                note.status = Task.isCancelled || offline || transcribingID == nil ? "queued" : "failed"
                note.error = Task.isCancelled ? nil : error.localizedDescription
                do { try save(note) } catch { issue = "Could not save transcription status: \(error.localizedDescription)" }
                if !Task.isCancelled && issue == nil { issue = note.error }
                transcribingID = nil
                return
            }
            transcribingID = nil
        }
    }
}
