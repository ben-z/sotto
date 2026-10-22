import Foundation
import Testing
@testable import SottoCore

@MainActor private func textFixture(_ library: NoteLibrary) throws -> RecordingRecord {
    let note = try library.create(model: "whisper-large-v3-turbo", language: "en")
    try Data([1, 2, 3]).write(to: library.archive.audioURL(note))
    try library.queue(note)
    return note
}

@MainActor @Test func textRevisionFollowsWritesAndReloads() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = NoteLibrary(archive: try Archive(directory: directory))
    defer { try! FileManager.default.removeItem(at: directory) }
    let note = try textFixture(library)
    let original = library.textRevision
    try library.rename(note, to: "A title")
    #expect(library.textRevision == original)
    try library.saveText("My saved edits", for: note)
    #expect(library.textRevision == original + 1)
    #expect(throws: (any Error).self) { try library.useMachineTranscript(for: note) }
    #expect(library.textRevision == original + 1)
    try "Machine text".write(to: directory.appendingPathComponent("\(note.id).txt"), atomically: true, encoding: .utf8)
    try library.useMachineTranscript(for: note)
    #expect(library.textRevision == original + 2)
    try library.reload()
    #expect(library.textRevision == original + 3)
    try await library.reloadAsync()
    #expect(library.textRevision == original + 4)
}

@MainActor @Test func historyPublicationDoesNotInvalidateSelectedText() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = NoteLibrary(archive: try Archive(directory: directory))
    defer { try! FileManager.default.removeItem(at: directory) }
    _ = try textFixture(source)
    _ = try textFixture(source)
    let history = NoteLibrary(archive: source.archive)
    let original = history.textRevision
    var versions: [Int] = []
    try await history.loadHistory { _ in versions.append(history.textRevision) }
    #expect(history.notes.count == 2)
    #expect(!versions.isEmpty)
    #expect(versions.allSatisfy { $0 == original })
}

@MainActor @Test func sameMetadataRetranscriptionStillInvalidatesText() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = NoteLibrary(archive: try Archive(directory: directory))
    defer { try! FileManager.default.removeItem(at: directory) }
    let note = try textFixture(library)
    let prefix = "One two three four five six seven eight nine "
    await library.process(ids: [note.id], key: { "fixture" }) { _, _, _ in
        TranscriptionResult(text: prefix + "first ending", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
    }
    let first = try #require(library.notes.first)
    let revision = library.textRevision
    try library.transcribe([note.id], model: first.model, language: first.language)
    await library.process(ids: [note.id], key: { "fixture" }) { _, _, _ in
        TranscriptionResult(text: prefix + "different ending", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
    }
    let second = try #require(library.notes.first)
    #expect(first.status == second.status)
    #expect(first.generatedTitle == second.generatedTitle)
    #expect(first.requestID == second.requestID)
    #expect(first.requestMilliseconds == second.requestMilliseconds)
    #expect(library.textRevision == revision + 1)
    #expect(try library.text(for: note) == prefix + "different ending")
}

@MainActor @Test func returnedTextInvalidatesWhenMetadataWriteFails() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = NoteLibrary(archive: try Archive(directory: directory))
    defer { try! FileManager.default.removeItem(at: directory) }
    let note = try textFixture(library)
    try library.saveText("Keep my edits", for: note)
    let revision = library.textRevision
    await library.process(ids: [note.id], key: { "fixture" }) { _, _, _ in
        let metadata = directory.appendingPathComponent("\(note.id).json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        return TranscriptionResult(text: "Retained machine result", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
    }
    #expect(library.issue != nil)
    #expect(library.textRevision == revision + 1)
    #expect(try library.machineTranscript(for: note) == "Retained machine result")
    #expect(try library.text(for: note) == "Keep my edits")
}

@MainActor @Test func selectedTextReadsRunWithoutAnActorHopAndPreserveErrors() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = NoteLibrary(archive: try Archive(directory: directory))
    defer { try! FileManager.default.removeItem(at: directory) }
    let note = try textFixture(library)
    try library.saveText("My edits", for: note)
    try "Machine text".write(to: directory.appendingPathComponent("\(note.id).txt"), atomically: true, encoding: .utf8)
    // These synchronous calls in a detached task enforce the nonisolated read boundary.
    let snapshot = try await Task.detached {
        (try library.text(for: note), try library.machineTranscript(for: note),
         library.hasEditedText(for: note), library.hasMachineTranscript(for: note))
    }.value
    #expect(snapshot.0 == "My edits")
    #expect(snapshot.1 == "Machine text")
    #expect(snapshot.2 && snapshot.3)
    try Data([0xff]).write(to: directory.appendingPathComponent("\(note.id).md"))
    let result = await Task.detached { Result { try library.text(for: note) } }.value
    switch result {
    case .success: Issue.record("Unreadable saved edits must not become empty text or a machine transcript")
    case .failure: break
    }
}
