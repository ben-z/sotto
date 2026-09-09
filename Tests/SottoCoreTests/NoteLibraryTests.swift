import Foundation
import Testing
@testable import SottoCore

@MainActor
private func queuedNote(_ library: NoteLibrary) throws -> RecordingRecord {
    let note = try library.create(model: "whisper-large-v3-turbo", language: "en")
    try Data([1, 2, 3]).write(to: library.archive.audioURL(note))
    try library.queue(note, duration: 2)
    return note
}

@MainActor @Test func notesRecoverDurableQueueAndInterruptedRecording() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    var queued = try queuedNote(library)
    queued.status = "transcribing"; try library.save(queued)
    let interrupted = try library.create(model: "whisper-large-v3", language: nil)
    let restored = try NoteLibrary(directory: directory)
    #expect(restored.notes.first { $0.id == queued.id }?.status == "queued")
    #expect(restored.notes.first { $0.id == interrupted.id }?.status == "interrupted")
    #expect(try Data(contentsOf: restored.archive.audioURL(queued)) == Data([1, 2, 3]))
}

@MainActor @Test func missingKeyAndOfflineKeepAudioQueued() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let note = try queuedNote(library)
    await library.process(key: { throw SottoError("Add a key") }) { _, _, _ in
        Issue.record("Must not upload without a key")
        throw SottoError("Unexpected upload")
    }
    #expect(library.notes.first?.status == "queued")
    #expect(library.issue == "Add a key")
    await library.process(key: { "fixture" }) { _, _, _ in throw URLError(.notConnectedToInternet) }
    #expect(library.notes.first?.status == "queued")
    #expect(FileManager.default.fileExists(atPath: library.archive.audioURL(note).path))
}

@MainActor @Test func queueIncludesNewNotesAndPreservesEditsDuringUpload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let first = try queuedNote(library)
    var uploaded: [String] = []
    await library.process(key: { "fixture" }) { _, _, note in
        uploaded.append(note.id)
        if note.id == first.id {
            _ = try queuedNote(library)
            try library.rename(note, to: "Ideas")
            try library.saveText("My edited note", for: note)
        }
        return TranscriptionResult(text: "Original transcript", rawResponse: Data("{}".utf8), milliseconds: 10, requestID: nil)
    }
    #expect(uploaded.count == 2)
    #expect(Set(uploaded).count == 2)
    #expect(library.notes.allSatisfy { $0.status == "complete" })
    #expect(library.notes.first { $0.id == first.id }?.title == "Ideas")
    #expect(try library.text(for: first) == "My edited note")
    #expect(try String(contentsOf: directory.appendingPathComponent("\(first.id).txt"), encoding: .utf8) == "Original transcript")
}

@MainActor @Test func failedUploadRequiresExplicitRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    _ = try queuedNote(library)
    await library.process(key: { "fixture" }) { _, _, _ in throw SottoError("Key rejected") }
    #expect(library.notes.first?.status == "failed")
    await library.process(key: { "fixture" }) { _, _, _ in
        Issue.record("Failed requests must not loop")
        throw SottoError("Unexpected retry")
    }
    try library.queue(#require(library.notes.first))
    #expect(library.notes.first?.status == "queued")
}

@MainActor @Test func reentrantProcessingDoesNotUploadTwice() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    _ = try queuedNote(library)
    var calls = 0
    await library.process(key: { "fixture" }) { _, _, _ in
        calls += 1
        await library.process(key: { "fixture" }) { _, _, _ in
            Issue.record("Only one upload may run")
            throw SottoError("Duplicate upload")
        }
        return TranscriptionResult(text: "Done", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
    }
    #expect(calls == 1)
    #expect(library.transcribingID == nil)
}
