import Foundation
import Testing
@testable import SottoCore

private let importedAudioExtensions = ["m4a", "wav", "mp3", "flac", "ogg", "webm", "mp4"]

private func importedAudioFixture(_ archive: Archive, extension ext: String) throws -> RecordingRecord {
    var note = try archive.newRecord(model: "fixture", language: "en", prompt: "", contextTerms: [])
    note.audioFile = "\(note.id).\(ext)"
    try Data("Retained \(ext) audio".utf8).write(to: archive.audioURL(note))
    try archive.complete(&note, with: TranscriptionResult(text: "Imported transcript", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: "fixture"))
    try "Saved edits".write(to: archive.directory.appendingPathComponent("\(note.id).md"), atomically: true, encoding: .utf8)
    return note
}

private func importedAudioSnapshot(_ directory: URL) throws -> [String: Data] {
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
}

@MainActor @Test func importedAudioFormatsLoadAndSupportOrdinaryMutations() async throws {
    for ext in importedAudioExtensions {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let archive = try Archive(directory: directory)
        let note = try importedAudioFixture(archive, extension: ext)
        let original = try importedAudioSnapshot(directory)
        let library = try NoteLibrary(directory: directory)
        try await library.reloadAsync()
        let history = NoteLibrary(archive: archive)
        try await history.loadHistory(activeRecordingID: nil) { _ in }
        #expect(history.notes.first?.audioFile == note.audioFile)
        #expect(try importedAudioSnapshot(directory) == original)

        try library.rename(note, to: "Imported title", activeRecordingID: nil)
        try library.saveText("New edits", for: note)
        #expect(try library.text(for: note) == "New edits")
        try library.useMachineTranscript(for: note)
        #expect(try library.text(for: note) == "Imported transcript")
        try library.transcribe([note.id], model: "new-model", language: "fr")
        #expect(library.notes.first?.status == "queued" && library.notes.first?.audioFile == note.audioFile)
        await library.process(key: { "fixture" }) { url, _, uploading in
            #expect(url == archive.audioURL(note) && uploading.audioFile == note.audioFile)
            return TranscriptionResult(text: "Retranscribed import", rawResponse: Data("{}".utf8), milliseconds: 2, requestID: "retry")
        }
        #expect(library.issue == nil && library.notes.first?.status == "complete")
        #expect(try library.text(for: note) == "Retranscribed import")
        #expect(try Data(contentsOf: archive.audioURL(note)) == Data("Retained \(ext) audio".utf8))
    }
}

@MainActor @Test func importedAudioFormatsLoadAndRecoverUnfinishedOperations() async throws {
    for ext in importedAudioExtensions {
        for state in ["recording", "transcribing"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try! FileManager.default.removeItem(at: directory) }
            let archive = try Archive(directory: directory)
            var note = try importedAudioFixture(archive, extension: ext)
            note.status = state; try archive.save(note)
            let original = try importedAudioSnapshot(directory)
            let library = NoteLibrary(archive: archive)
            try await library.loadHistory(activeRecordingID: nil) { _ in }
            #expect(library.notes.first?.status == state)
            #expect(try importedAudioSnapshot(directory) == original)

            try library.recover(note.id, activeRecordingID: nil)

            #expect(library.notes.first?.status == (state == "recording" ? "interrupted" : "failed"))
            #expect(try library.text(for: note) == "Saved edits")
            #expect(try Data(contentsOf: archive.audioURL(note)) == Data("Retained \(ext) audio".utf8))
        }
    }
}

@MainActor @Test func importedAudioDeletionRemovesSelectedFilesAndPreservesAnotherNote() throws {
    for ext in importedAudioExtensions {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let archive = try Archive(directory: directory)
        let selected = try importedAudioFixture(archive, extension: ext)
        let other = try importedAudioFixture(archive, extension: "m4a")
        let retained = try importedAudioSnapshot(directory).filter { $0.key.hasPrefix(other.id + ".") }
        let library = try NoteLibrary(directory: directory)

        try library.delete([selected.id])

        #expect(library.notes.map(\.id) == [other.id])
        #expect(try importedAudioSnapshot(directory) == retained)
        #expect(!FileManager.default.fileExists(atPath: archive.audioURL(selected).path))
    }
}

@MainActor @Test func importedAudioValidationRejectsPathsForeignIDsAndMetadataExtensions() async throws {
    for invalid in ["wrong-id", "foreign.wav", "../NOTE.wav", "subdir/NOTE.wav", "/NOTE.wav", "NOTE.txt", "NOTE.md", "NOTE.json", "NOTE.response.json", "NOTE.aac", "NOTE", ""] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let archive = try Archive(directory: directory)
        var note = try importedAudioFixture(archive, extension: "wav")
        let metadata = directory.appendingPathComponent("\(note.id).json")
        if invalid == "wrong-id" { note.id = "another-note" }
        else { note.audioFile = invalid.replacingOccurrences(of: "NOTE", with: note.id) }
        try JSONFile.write(note, to: metadata)
        let original = try importedAudioSnapshot(directory)

        #expect(throws: NoteLoadFailure.self) { try NoteLibrary(directory: directory) }
        let library = NoteLibrary(archive: archive)
        await #expect(throws: NoteLoadFailure.self) { try await library.loadHistory(activeRecordingID: nil) { _ in } }
        #expect(library.notes.isEmpty)
        #expect(try importedAudioSnapshot(directory) == original)
    }
}
