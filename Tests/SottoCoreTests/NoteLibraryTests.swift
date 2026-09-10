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

@MainActor @Test func finishingRecordingPreservesTitleEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let recording = try library.create(model: "whisper-large-v3-turbo", language: "en")
    try Data([1, 2, 3]).write(to: library.archive.audioURL(recording))
    try library.rename(recording, to: "A thought while recording")
    try library.queue(recording, duration: 5)
    #expect(library.notes.first?.title == "A thought while recording")
    #expect(library.notes.first?.durationSeconds == 5)
}

@MainActor @Test func cancelledUploadReturnsToDurableQueue() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    _ = try queuedNote(library)
    let (started, signal) = AsyncStream<Void>.makeStream()
    let task = Task {
        await library.process(key: { "fixture" }) { _, _, _ in
            signal.yield(()); signal.finish()
            try await Task.sleep(for: .seconds(60))
            throw SottoError("Cancellation did not reach the upload")
        }
    }
    for await _ in started { break }
    task.cancel()
    await task.value
    #expect(library.notes.first?.status == "queued")
    #expect(library.notes.first?.error == nil)
    #expect(library.transcribingID == nil)
    #expect(try NoteLibrary(directory: directory).notes.first?.status == "queued")
}

@MainActor @Test func unreadableMetadataIdentifiesTheFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: directory.appendingPathComponent("broken.json"))
    do {
        _ = try NoteLibrary(directory: directory)
        Issue.record("Corrupt metadata must be reported")
    } catch { #expect(error.localizedDescription.contains("broken.json")) }
}

@MainActor @Test func completedResponseSurvivesLateCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let note = try queuedNote(library)
    let task = Task {
        await library.process(key: { "fixture" }) { _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return TranscriptionResult(text: "Already received", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
        }
    }
    await task.value
    #expect(library.notes.first?.status == "complete")
    #expect(try library.text(for: note) == "Already received")
    #expect(library.issue == nil)
}

@MainActor @Test func retranscriptionKeepsEditsAndTracksCompletedModel() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let note = try queuedNote(library)
    await library.process(key: { "fixture" }) { _, _, _ in
        TranscriptionResult(text: "Planning the next garden project", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
    }
    #expect(library.notes[0].displayTitle == "Planning the next garden project")
    try library.rename(note, to: "Garden")
    try library.saveText("My own notes", for: note)
    try library.transcribe([note.id], model: "whisper-large-v3", language: nil)
    #expect(library.notes[0].transcribedModel == "whisper-large-v3-turbo")
    await library.process(key: { "fixture" }) { _, _, request in
        #expect(request.model == "whisper-large-v3")
        #expect(request.language == nil)
        return TranscriptionResult(text: "A better transcript", rawResponse: Data("{}".utf8), milliseconds: 2, requestID: nil)
    }
    let restored = try NoteLibrary(directory: directory)
    #expect(restored.notes[0].displayTitle == "Garden")
    #expect(restored.notes[0].transcribedModel == "whisper-large-v3")
    #expect(try restored.text(for: note) == "My own notes")
    try restored.rename(note, to: " ")
    #expect(restored.notes[0].displayTitle == "A better transcript")
    #expect(try String(contentsOf: directory.appendingPathComponent("\(note.id).txt"), encoding: .utf8) == "A better transcript")
}

@MainActor @Test func batchDeletionRemovesOnlySelectedNotesAndProtectsActiveWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let first = try queuedNote(library)
    let second = try queuedNote(library)
    let active = try library.create(model: "fixture", language: "en")
    #expect(throws: (any Error).self) { try library.delete([first.id, active.id]) }
    #expect(FileManager.default.fileExists(atPath: library.archive.audioURL(first).path))
    try library.saveText("Edited", for: first)
    await library.process(key: { "fixture" }) { _, _, note in
        #expect(throws: (any Error).self) { try library.delete([note.id]) }
        return TranscriptionResult(text: "Transcript", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
    }
    try library.delete([first.id, second.id])
    #expect(library.notes.map(\.id) == [active.id])
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["\(active.id).json"])
}

@MainActor @Test func batchTranscriptionValidatesWholeSelectionBeforeQueueing() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    var first = try queuedNote(library)
    first.status = "complete"; try library.save(first)
    let active = try library.create(model: "fixture", language: nil)
    #expect(throws: (any Error).self) { try library.transcribe([first.id, active.id], model: "new", language: nil) }
    #expect(library.notes.first { $0.id == first.id }?.status == "complete")
    #expect(library.notes.first { $0.id == first.id }?.model == first.model)
}

@MainActor @Test func recordingPlaceAndTimeZoneSurviveRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    var note = try queuedNote(library)
    note.timeZoneIdentifier = "America/Los_Angeles"
    note.location = RecordingLocation(latitude: 37.3, longitude: -122.1, accuracyMeters: 100)
    try library.save(note)
    let restored = try NoteLibrary(directory: directory).notes[0]
    #expect(restored.timeZoneIdentifier == "America/Los_Angeles")
    #expect(restored.location?.latitude == 37.3)
    #expect(restored.location?.accuracyMeters == 100)
}

@MainActor @Test func encoderFailureRetainsAudioWithoutUploading() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let note = try library.create(model: "fixture", language: "en")
    try Data([1, 2, 3]).write(to: library.archive.audioURL(note))
    var stopped = false
    #expect(throws: (any Error).self) {
        try library.finishRecording(note, recordingError: "Encoder failed") { stopped = true; return 2 }
    }
    #expect(stopped)
    #expect(library.notes[0].status == "interrupted")
    #expect(library.notes[0].error == "Encoder failed")
    #expect(try NoteLibrary(directory: directory).notes[0].status == "interrupted")
    #expect(try Data(contentsOf: library.archive.audioURL(note)) == Data([1, 2, 3]))
    await library.process(key: { "fixture" }) { _, _, _ in
        Issue.record("An encoder failure must not trigger an upload")
        throw SottoError("Unexpected upload")
    }
    try library.delete([note.id])
    #expect(library.notes.isEmpty)
}

@MainActor @Test func stopFailureCanBeRetriedWithoutRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let note = try library.create(model: "fixture", language: "en")
    try Data([1, 2, 3]).write(to: library.archive.audioURL(note))
    #expect(throws: (any Error).self) {
        try library.finishRecording(note, recordingError: nil) { throw SottoError("Audio session could not deactivate") }
    }
    #expect(library.notes[0].status == "interrupted")
    try library.transcribe([note.id], model: "fixture", language: "en")
    #expect(library.notes[0].status == "queued")
}

@MainActor @Test func finalizationWriteFailureLeavesStoppedNoteEditable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let note = try library.create(model: "fixture", language: "en")
    try Data([1, 2, 3]).write(to: library.archive.audioURL(note))
    let metadata = directory.appendingPathComponent("\(note.id).json")
    try FileManager.default.removeItem(at: metadata)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
    do {
        try library.finishRecording(note, recordingError: nil) { 2 }
        Issue.record("The failed metadata write must be reported")
    } catch { #expect(error.localizedDescription.contains("Could not save interrupted status")) }
    #expect(library.notes[0].status == "interrupted")
    try FileManager.default.removeItem(at: metadata)
    try library.transcribe([note.id], model: "fixture", language: "en")
    #expect(try NoteLibrary(directory: directory).notes[0].status == "queued")
}
