import Foundation
import Testing
@testable import SottoCore

private func unfinishedFixture(_ archive: Archive, status: String) throws -> RecordingRecord {
    var note = try archive.newRecord(model: "fixture", language: "en", prompt: "", contextTerms: [])
    note.status = status
    try archive.save(note)
    try Data("retained audio".utf8).write(to: archive.audioURL(note))
    try "Retained edits".write(to: archive.directory.appendingPathComponent("\(note.id).md"), atomically: true, encoding: .utf8)
    return note
}

@MainActor @Test func recoveryReadsCurrentMetadataAndKeepsAudioAndEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    var note = try unfinishedFixture(archive, status: "recording")
    let library = try NoteLibrary(directory: directory)
    note.title = "Changed on another device"
    try archive.save(note)

    try library.recover(note.id, activeRecordingID: nil)

    #expect(library.notes[0].status == "interrupted")
    #expect(library.notes[0].title == "Changed on another device")
    #expect(try NoteLibrary(directory: directory).notes[0].status == "interrupted")
    #expect(try Data(contentsOf: archive.audioURL(note)) == Data("retained audio".utf8))
    #expect(try library.text(for: note) == "Retained edits")
    try library.rename(note, to: "Recovered title", activeRecordingID: nil)
    try library.saveText("Recovered edits", for: note)
    try library.transcribe([note.id], model: "fixture", language: "en")
    #expect(library.notes[0].status == "queued")
}

@MainActor @Test func recoveryPreservesCompletionFromAnotherDevice() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    var note = try unfinishedFixture(archive, status: "transcribing")
    let library = try NoteLibrary(directory: directory)
    try archive.complete(&note, with: TranscriptionResult(text: "Completed elsewhere", rawResponse: Data("{}".utf8), milliseconds: 2, requestID: "remote"))
    let metadata = directory.appendingPathComponent("\(note.id).json")
    let completed = try Data(contentsOf: metadata)

    #expect(throws: SottoError.self) { try library.recover(note.id, activeRecordingID: nil) }

    #expect(library.notes[0].status == "complete")
    #expect(library.notes[0].requestID == "remote")
    #expect(library.notes[0].error == nil)
    #expect(try Data(contentsOf: metadata) == completed)
    #expect(try library.machineTranscript(for: note) == "Completed elsewhere")
    #expect(try library.text(for: note) == "Retained edits")
    #expect(try Data(contentsOf: archive.audioURL(note)) == Data("retained audio".utf8))
}

@MainActor @Test func recoveryRejectsCurrentLibraryUpload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let note = try library.create(model: "fixture", language: "en")
    try Data("retained audio".utf8).write(to: library.archive.audioURL(note))
    try library.queue(note)
    var attempted = false
    await library.process(key: { "fixture" }) { _, _, current in
        attempted = true
        #expect(library.transcribingID == current.id)
        let metadata = directory.appendingPathComponent("\(current.id).json")
        let original = try Data(contentsOf: metadata)
        #expect(throws: SottoError.self) { try library.recover(current.id, activeRecordingID: nil) }
        #expect(library.notes[0].status == "transcribing")
        #expect(try Data(contentsOf: metadata) == original)
        return TranscriptionResult(text: "Completed locally", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
    }
    #expect(attempted)
    #expect(library.notes[0].status == "complete")
}

@MainActor @Test func recoveryReportsUnreadableCurrentMetadataWithoutUnlockingNote() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    let note = try unfinishedFixture(archive, status: "recording")
    let library = try NoteLibrary(directory: directory)
    let metadata = directory.appendingPathComponent("\(note.id).json")
    try Data("{".utf8).write(to: metadata)

    do {
        try library.recover(note.id, activeRecordingID: nil)
        Issue.record("Unreadable current metadata must prevent recovery")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .readNote)
        #expect(failure.url == metadata)
        #expect(failure.underlying is DecodingError)
    }
    #expect(library.notes[0].status == "recording")
    #expect(try Data(contentsOf: metadata) == Data("{".utf8))
    #expect(throws: SottoError.self) { try library.delete([note.id]) }
}

@MainActor @Test func recoveryValidatesCurrentMetadataIdentity() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    var note = try unfinishedFixture(archive, status: "transcribing")
    let library = try NoteLibrary(directory: directory)
    note.audioFile = "another-note.m4a"
    try archive.save(note)
    let metadata = directory.appendingPathComponent("\(note.id).json")
    let original = try Data(contentsOf: metadata)

    #expect(throws: NoteLoadFailure.self) { try library.recover(note.id, activeRecordingID: nil) }

    #expect(library.notes[0].status == "transcribing")
    #expect(try Data(contentsOf: metadata) == original)
}
