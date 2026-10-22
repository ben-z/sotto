import Foundation
import Combine
import OSLog

/// Each audio file and its metadata are the durable queue. No database or worker service.
@MainActor
public final class NoteLibrary: ObservableObject {
    @Published public private(set) var notes: [RecordingRecord] = []
    @Published public private(set) var transcribingID: String?
    @Published public private(set) var issue: String?
    @Published public private(set) var textRevision = 0
    public let archive: Archive
    private let log = Logger(subsystem: "dev.sotto.notes", category: "queue")
    // Live edits and deletions take precedence over the history snapshot.
    private var historyChanges: Set<String>?

    public init(archive: Archive) { self.archive = archive }

    /// Visible notes reread their text after local writes or an explicit folder refresh.
    public func invalidateText() { textRevision += 1 }

    public convenience init(directory: URL) throws {
        self.init(archive: try Archive(directory: directory))
        try reload()
    }

    public func reload() throws {
        notes = try Self.readRecords(archive: archive)
        invalidateText()
    }

    public func reloadAsync() async throws {
        let archive = archive
        notes = try await Task.detached {
            try Self.readRecords(archive: archive)
        }.value
        invalidateText()
    }

    /// Publish each validated saved note without changing its files, preserving live changes.
    public func loadHistory(activeRecordingID: String?, progress: @escaping @MainActor @Sendable (NoteLoadProgress) -> Void) async throws {
        guard historyChanges == nil else { throw SottoError("Note history is already loading.") }
        historyChanges = Set([activeRecordingID, transcribingID].compactMap { $0 })
        defer { historyChanges = nil }
        let archive = archive
        let task = Task.detached {
            let files = try Self.metadataFiles(archive: archive)
            let ids = Set(files.map { $0.deletingPathExtension().lastPathComponent })
            await progress(.reading(loaded: 0, total: files.count))
            for (index, url) in files.enumerated() {
                try Task.checkCancellation()
                let id = url.deletingPathExtension().lastPathComponent
                do {
                    let note = try Self.readRecord(url)
                    try Task.checkCancellation()
                    await self.publishHistory(note)
                } catch {
                    try Task.checkCancellation()
                    // A note deleted through this library can disappear during its read.
                    guard await self.deletedDuringHistoryLoad(id) else { throw error }
                }
                await progress(.reading(loaded: index + 1, total: files.count))
            }
            try Task.checkCancellation()
            return ids
        }
        let ids = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        notes.removeAll { !ids.contains($0.id) && historyChanges?.contains($0.id) == false }
    }

    private func deletedDuringHistoryLoad(_ id: String) -> Bool {
        historyChanges?.contains(id) == true && !notes.contains { $0.id == id }
    }

    private func publishHistory(_ note: RecordingRecord) {
        guard historyChanges?.contains(note.id) == false else { return }
        var updated = notes.filter { $0.id != note.id }
        let index = updated.firstIndex { $0.startedAt < note.startedAt } ?? updated.endIndex
        updated.insert(note, at: index)
        notes = updated
    }

    /// Recovery is an explicit action after stopping the operation on every device.
    public func recover(_ id: String, activeRecordingID: String?) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw SottoError("This note is no longer available.")
        }
        guard id != activeRecordingID, id != transcribingID else {
            throw SottoError("Stop this recording or transcription before recovering the note.")
        }
        defer { invalidateText() }
        let url = archive.directory.appendingPathComponent("\(id).json")
        var note = try Self.readRecord(url)
        guard note.hasUnfinishedOperation else {
            historyChanges?.insert(id)
            notes[index] = note
            throw SottoError("This note changed elsewhere. Its current status has been loaded; review it before making changes.")
        }
        note.status = note.status == "recording" ? "interrupted" : "failed"
        note.error = "Recovered unfinished operation. Select Transcribe to try again."
        do { try save(note) }
        catch { throw NoteLoadFailure(operation: .recoverNote, url: url, underlying: error) }
    }

    /// Publish a library only after every metadata read succeeds.
    public static func open(directory: URL, progress: @escaping @MainActor @Sendable (NoteLoadProgress) -> Void) async throws -> NoteLibrary {
        progress(.opening)
        let archive: Archive
        do { archive = try await Task.detached { try Archive(directory: directory) }.value }
        catch { throw NoteLoadFailure(operation: .openFolder, url: directory, underlying: error) }
        let library = NoteLibrary(archive: archive)
        try await library.loadHistory(activeRecordingID: nil, progress: progress)
        return library
    }

    nonisolated private static func metadataFiles(archive: Archive) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".response.json") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        } catch { throw NoteLoadFailure(operation: .openFolder, url: archive.directory, underlying: error) }
    }

    nonisolated private static func readRecord(_ url: URL) throws -> RecordingRecord {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let note: RecordingRecord
        do {
            note = try decoder.decode(RecordingRecord.self, from: Data(contentsOf: url))
            guard note.id == url.deletingPathExtension().lastPathComponent,
                  note.audioFile == "\(note.id).m4a" else { throw SottoError("Invalid note metadata") }
        } catch { throw NoteLoadFailure(operation: .readNote, url: url, underlying: error) }
        return note
    }

    nonisolated private static func loadMissingTitle(for note: inout RecordingRecord, archive: Archive) throws {
        if (note.title == nil || note.title == "") && note.generatedTitle == nil && note.status == "complete" {
            let transcript = archive.directory.appendingPathComponent("\(note.id).txt")
            if FileManager.default.fileExists(atPath: transcript.path) {
                do { note.generatedTitle = RecordingRecord.suggestedTitle(from: try String(contentsOf: transcript, encoding: .utf8)) }
                catch { throw NoteLoadFailure(operation: .readNote, url: transcript, underlying: error) }
            }
        }
    }

    nonisolated private static func readRecords(archive: Archive) throws -> [RecordingRecord] {
        try metadataFiles(archive: archive).map { try readRecord($0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func create(model: String, language: String?) throws -> RecordingRecord {
        let note = try archive.newRecord(model: model, language: language, prompt: "", contextTerms: [])
        historyChanges?.insert(note.id)
        notes.append(note)
        notes.sort { $0.startedAt > $1.startedAt }
        return note
    }

    public func save(_ note: RecordingRecord) throws {
        try archive.save(note)
        historyChanges?.insert(note.id)
        log.notice("Note \(note.id, privacy: .public): \(note.status, privacy: .public)")
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note }
        else { notes.append(note); notes.sort { $0.startedAt > $1.startedAt } }
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
        let cached = notes.filter { ids.contains($0.id) }
        guard cached.count == ids.count else { throw SottoError("Some selected notes are no longer available.") }
        let selected = try cached.map {
            try Self.readRecord(archive.directory.appendingPathComponent("\($0.id).json"))
        }
        guard !selected.contains(where: { $0.hasUnfinishedOperation || $0.id == transcribingID }) else {
            throw SottoError("Wait for active recordings and transcriptions to finish. Recover unfinished notes before changing them.")
        }
        return selected
    }

    private func editableMetadataNote(_ id: String, activeRecordingID: String?) throws -> RecordingRecord {
        guard notes.contains(where: { $0.id == id }) else {
            throw SottoError("This note is no longer available.")
        }
        let note = try Self.readRecord(archive.directory.appendingPathComponent("\(id).json"))
        guard !note.hasUnfinishedOperation || id == activeRecordingID || id == transcribingID else {
            throw SottoError("Recover this unfinished note before changing it.")
        }
        return note
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
            historyChanges?.insert(note.id)
        }
    }

    nonisolated public func text(for note: RecordingRecord) throws -> String {
        for ext in ["md", "txt"] {
            let url = archive.directory.appendingPathComponent("\(note.id).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return try String(contentsOf: url, encoding: .utf8) }
        }
        return ""
    }

    nonisolated public func hasEditedText(for note: RecordingRecord) -> Bool {
        FileManager.default.fileExists(atPath: archive.directory.appendingPathComponent("\(note.id).md").path)
    }

    nonisolated public func hasMachineTranscript(for note: RecordingRecord) -> Bool {
        FileManager.default.fileExists(atPath: archive.directory.appendingPathComponent("\(note.id).txt").path)
    }

    nonisolated public func machineTranscript(for note: RecordingRecord) throws -> String {
        try String(contentsOf: archive.directory.appendingPathComponent("\(note.id).txt"), encoding: .utf8)
    }

    public func useMachineTranscript(for note: RecordingRecord) throws {
        _ = try editableNotes([note.id])
        _ = try machineTranscript(for: note)
        try FileManager.default.removeItem(at: archive.directory.appendingPathComponent("\(note.id).md"))
        invalidateText()
    }

    public func saveText(_ text: String, for note: RecordingRecord) throws {
        _ = try editableMetadataNote(note.id, activeRecordingID: nil)
        // Keep the machine transcript and raw response when a person edits their note.
        try text.write(to: archive.directory.appendingPathComponent("\(note.id).md"), atomically: true, encoding: .utf8)
        invalidateText()
    }

    public func rename(_ note: RecordingRecord, to title: String, activeRecordingID: String?) throws {
        var note = try editableMetadataNote(note.id, activeRecordingID: activeRecordingID)
        note.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.loadMissingTitle(for: &note, archive: archive)
        try save(note)
    }

    private func transcriptionNote(matching request: RecordingRecord, status: String) throws -> RecordingRecord {
        let note = try Self.readRecord(archive.directory.appendingPathComponent("\(request.id).json"))
        guard note.status == status, note.model == request.model, note.language == request.language,
              note.prompt == request.prompt, note.contextTerms == request.contextTerms else {
            throw SottoError("This note's transcription state changed. Refresh your notes before trying again.")
        }
        return note
    }

    /// Each queued request is attempted once. Failed attempts require explicit selection.
    public func process(ids: Set<String>? = nil, key: () throws -> String,
                        transcribe: (URL, String, RecordingRecord) async throws -> TranscriptionResult) async {
        guard transcribingID == nil else { return }
        issue = nil
        while let candidate = notes.reversed().first(where: { $0.status == "queued" && (ids == nil || ids!.contains($0.id)) }) {
            if Task.isCancelled { return }
            // Output files can change even if the final metadata write fails.
            defer { transcribingID = nil; invalidateText() }
            var note: RecordingRecord
            do { note = try transcriptionNote(matching: candidate, status: "queued") }
            catch { issue = error.localizedDescription; return }
            var completed = false
            do {
                let secret = try key()
                note.status = "transcribing"; note.error = nil
                try save(note)
                transcribingID = note.id
                let result = try await transcribe(archive.audioURL(note), secret, note)
                // Persist a returned result even if cancellation arrived with it.
                do { note = try transcriptionNote(matching: candidate, status: "transcribing") }
                catch {
                    issue = "The transcription could not be saved: \(error.localizedDescription)"
                    return
                }
                try archive.complete(&note, with: result)
                completed = true
                log.notice("Note \(note.id, privacy: .public): complete")
                guard let index = notes.firstIndex(where: { $0.id == note.id }) else {
                    throw SottoError("The transcribed recording is no longer in the note list.")
                }
                notes[index] = note
            } catch {
                if completed {
                    issue = "Transcription was saved, but the note list could not refresh: \(error.localizedDescription)"
                    return
                }
                let originalError = error.localizedDescription
                do {
                    note = try transcriptionNote(matching: candidate, status: transcribingID == candidate.id ? "transcribing" : "queued")
                    note.status = "failed"
                    note.error = Task.isCancelled ? "Transcription was cancelled. Retry when ready." : originalError
                    try save(note)
                    if !Task.isCancelled { issue = originalError }
                } catch {
                    issue = "\(originalError) · Could not save transcription status: \(error.localizedDescription)"
                }
                return
            }
        }
    }
}
