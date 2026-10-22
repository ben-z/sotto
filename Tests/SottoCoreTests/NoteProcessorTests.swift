import Foundation
import Testing
@testable import SottoCore

@MainActor private func processorFixture(_ directory: URL) throws -> (NoteLibrary, RecordingRecord) {
    let archive = try Archive(directory: directory)
    var note = try archive.newRecord(model: "fixture", language: "en", prompt: "Original prompt", contextTerms: ["Original"])
    note.status = "queued"; note.title = "Cached title"; note.startedAt = Date(timeIntervalSince1970: 1)
    try archive.save(note)
    try Data("Retained audio".utf8).write(to: archive.audioURL(note))
    try "Existing edits".write(to: directory.appendingPathComponent("\(note.id).md"), atomically: true, encoding: .utf8)
    try "Previous machine text".write(to: directory.appendingPathComponent("\(note.id).txt"), atomically: true, encoding: .utf8)
    try Data("Previous response".utf8).write(to: directory.appendingPathComponent("\(note.id).response.json"))
    return (try NoteLibrary(directory: directory), note)
}

private func processorSnapshot(_ directory: URL) throws -> [String: Data] {
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
}

private func changeProcessorMetadata(_ scenario: String, note: RecordingRecord, archive: Archive) throws {
    let metadata = archive.directory.appendingPathComponent("\(note.id).json")
    if scenario == "deleted" { try FileManager.default.removeItem(at: metadata); return }
    if scenario == "invalid" { try Data("{".utf8).write(to: metadata); return }
    var current = note
    switch scenario {
    case "wrong-id": current.id = "another-note"
    case "wrong-audio": current.audioFile = "another-note.m4a"
    case "model": current.model = "another-model"
    case "language": current.language = "fr"
    case "prompt": current.prompt = "Changed prompt"
    case "terms": current.contextTerms = ["Changed"]
    default: current.status = scenario
    }
    try JSONFile.write(current, to: metadata)
}

@MainActor @Test func processorMetadataRejectsChangedQueueBeforeReadingKeyOrUploading() async throws {
    for scenario in ["deleted", "invalid", "wrong-id", "wrong-audio", "recording", "transcribing", "complete", "model", "language", "prompt", "terms"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let (library, note) = try processorFixture(directory)
        var second = try library.archive.newRecord(model: "fixture", language: "en", prompt: "", contextTerms: [])
        second.status = "queued"; second.startedAt = Date(timeIntervalSince1970: 2)
        try library.archive.save(second)
        try library.reload()
        try changeProcessorMetadata(scenario, note: note, archive: library.archive)
        let original = try processorSnapshot(directory)
        var keys = 0
        var uploads = 0

        await library.process(key: { keys += 1; return "fixture" }) { _, _, _ in
            uploads += 1
            return TranscriptionResult(text: "Unexpected result", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
        }

        #expect(keys == 0 && uploads == 0, "A changed \(scenario) candidate must stop the pass")
        #expect(library.issue != nil && library.transcribingID == nil)
        #expect(try processorSnapshot(directory) == original)
    }
}

@MainActor @Test func processorMetadataPreservesFreshFieldsAndLocalTextAtStartAndCompletion() async throws {
    for phase in ["before-start", "during-upload"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let (library, note) = try processorFixture(directory)
        func changed(_ original: RecordingRecord) -> RecordingRecord {
            var current = original
            current.title = "Fresh title"; current.locationStatus = "Fresh location"
            current.location = RecordingLocation(latitude: 1, longitude: 2, accuracyMeters: 3)
            return current
        }
        if phase == "before-start" { try library.archive.save(changed(note)) }

        await library.process(key: { "fixture" }) { _, _, uploading in
            if phase == "during-upload" { try library.archive.save(changed(uploading)) }
            try library.saveText("Local draft during upload", for: uploading)
            return TranscriptionResult(text: "Result", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: "local-request")
        }

        let saved = try #require(NoteLibrary(directory: directory).notes.first)
        #expect(saved.status == "complete" && saved.title == "Fresh title")
        #expect(saved.locationStatus == "Fresh location" && saved.transcribedModel == "fixture")
        #expect(saved.location?.latitude == 1 && saved.location?.longitude == 2 && saved.location?.accuracyMeters == 3)
        #expect(try library.text(for: note) == "Local draft during upload")
        #expect(try library.machineTranscript(for: note) == "Result")
        #expect(try Data(contentsOf: library.archive.audioURL(note)) == Data("Retained audio".utf8))
        #expect(library.issue == nil && library.transcribingID == nil)
    }
}

@MainActor @Test func processorMetadataRejectsCompletionConflictsWithoutChangingFiles() async throws {
    for scenario in ["deleted", "invalid", "wrong-id", "wrong-audio", "recording", "complete", "queued", "model", "language", "prompt", "terms"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let (library, note) = try processorFixture(directory)
        var conflict: [String: Data]?

        await library.process(key: { "fixture" }) { _, _, uploading in
            try changeProcessorMetadata(scenario, note: uploading, archive: library.archive)
            conflict = try processorSnapshot(directory)
            return TranscriptionResult(text: "Must not replace remote output", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
        }

        #expect(library.issue != nil && library.transcribingID == nil)
        #expect(try processorSnapshot(directory) == #require(conflict))
        #expect(try Data(contentsOf: library.archive.audioURL(note)) == Data("Retained audio".utf8))
    }
}

@MainActor @Test func processorMetadataDoesNotOverwriteFailureConflictsAndKeepsOriginalError() async throws {
    for scenario in ["deleted", "invalid", "wrong-id", "wrong-audio", "recording", "complete", "queued", "model", "language", "prompt", "terms"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let (library, _) = try processorFixture(directory)
        var conflict: [String: Data]?

        await library.process(key: { "fixture" }) { _, _, uploading in
            try changeProcessorMetadata(scenario, note: uploading, archive: library.archive)
            conflict = try processorSnapshot(directory)
            throw SottoError("Original upload failure")
        }

        let issue = try #require(library.issue)
        #expect(issue.contains("Original upload failure") && issue.contains("Could not save transcription status"))
        #expect(try processorSnapshot(directory) == #require(conflict))
        #expect(library.transcribingID == nil)
    }
}

@MainActor @Test func processorMetadataPreservesFreshFieldsWhenSavingFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let (library, note) = try processorFixture(directory)

    await library.process(key: { "fixture" }) { _, _, uploading in
        var current = uploading
        current.title = "Fresh failure title"; current.locationStatus = "Fresh failure location"
        try library.archive.save(current)
        throw SottoError("Original upload failure")
    }

    let saved = try #require(NoteLibrary(directory: directory).notes.first)
    #expect(saved.status == "failed" && saved.title == "Fresh failure title")
    #expect(saved.locationStatus == "Fresh failure location" && saved.error == "Original upload failure")
    #expect(library.issue == "Original upload failure" && library.transcribingID == nil)
    #expect(try library.machineTranscript(for: note) == "Previous machine text")
}

@MainActor @Test func processorMetadataReportsOriginalAndStatusWriteErrors() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let (library, note) = try processorFixture(directory)
    defer {
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try! FileManager.default.removeItem(at: directory)
    }

    await library.process(key: { "fixture" }) { _, _, _ in
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        throw SottoError("Original upload failure")
    }

    let issue = try #require(library.issue)
    #expect(issue.contains("Original upload failure") && issue.contains("Could not save transcription status"))
    #expect(try NoteLibrary(archive: library.archive).text(for: note) == "Existing edits")
    let metadata = directory.appendingPathComponent("\(note.id).json")
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(RecordingRecord.self, from: Data(contentsOf: metadata)).status == "transcribing")
    #expect(library.transcribingID == nil)
}
