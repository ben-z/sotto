import Foundation
import Testing
@testable import SottoCore

@MainActor private func locationFixture(_ directory: URL) throws -> (NoteLibrary, RecordingRecord) {
    let library = try NoteLibrary(directory: directory)
    var note = try library.create(model: "original-model", language: "en")
    note.status = "complete"; note.title = "Cached title"
    try library.save(note)
    try Data("Retained audio".utf8).write(to: library.archive.audioURL(note))
    try "Saved edits".write(to: directory.appendingPathComponent("\(note.id).md"), atomically: true, encoding: .utf8)
    return (library, note)
}

private func locationSnapshot(_ directory: URL) throws -> [String: Data] {
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
}

private func locationMetadata(_ note: RecordingRecord) throws -> Data {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
    return try encoder.encode(note)
}

@MainActor @Test func locationUpdatePreservesEveryOtherFreshMetadataField() throws {
    for status in ["complete", "queued", "failed"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let (library, note) = try locationFixture(directory)
        var current = note
        current.title = "Remote title"; current.generatedTitle = "Remote generated title"
        current.status = status; current.model = "remote-model"; current.language = "fr"
        current.prompt = "Remote prompt"; current.contextTerms = ["Remote term"]
        current.audioFile = "\(note.id).wav"; current.audioBytes = 123; current.durationSeconds = 4
        current.transcribedModel = "remote-completed-model"; current.requestID = "remote-request"
        current.requestMilliseconds = 42; current.error = "Remote message"; current.timeZoneIdentifier = "UTC"
        try library.archive.save(current)
        let original = try locationSnapshot(directory).filter { $0.key != "\(note.id).json" }
        let location = RecordingLocation(latitude: 1, longitude: 2, accuracyMeters: 3)

        try library.updateLocation(location, message: nil, for: note.id, activeRecordingID: nil)

        current.location = location; current.locationStatus = nil
        let saved = try #require(NoteLibrary(directory: directory).notes.first)
        #expect(try locationMetadata(saved) == locationMetadata(current))
        #expect(try locationMetadata(#require(library.notes.first)) == locationMetadata(current))
        #expect(try locationSnapshot(directory).filter { $0.key != "\(note.id).json" } == original)
    }
}

@MainActor @Test func locationUpdateRejectsMissingInvalidAndForeignActiveMetadataWithoutWriting() throws {
    for scenario in ["deleted", "invalid", "wrong-id", "wrong-audio", "recording", "transcribing"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let (library, note) = try locationFixture(directory)
        let metadata = directory.appendingPathComponent("\(note.id).json")
        switch scenario {
        case "deleted": try FileManager.default.removeItem(at: metadata)
        case "invalid": try Data("{".utf8).write(to: metadata)
        default:
            var current = note
            if scenario == "wrong-id" { current.id = "another-note" }
            else if scenario == "wrong-audio" { current.audioFile = "another-note.m4a" }
            else { current.status = scenario }
            try JSONFile.write(current, to: metadata)
        }
        let original = try locationSnapshot(directory)

        #expect(throws: (any Error).self) {
            try library.updateLocation(nil, message: "Location unavailable", for: note.id, activeRecordingID: nil)
        }

        #expect(try locationSnapshot(directory) == original, "A late location callback changed \(scenario) metadata")
        #expect(library.notes.first?.locationStatus == nil)
    }
}

@MainActor @Test func locationUpdateDoesNothingAfterLocalDeletion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let (library, note) = try locationFixture(directory)
    try library.delete([note.id])
    let original = try locationSnapshot(directory)

    try library.updateLocation(nil, message: "Late failure", for: note.id, activeRecordingID: nil)

    #expect(library.notes.isEmpty)
    #expect(try locationSnapshot(directory) == original)
}

@MainActor @Test func locationUpdateAllowsCurrentLocalRecordingAndRetainsNewTitle() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    var note = try library.create(model: "fixture", language: "en")
    note.title = "Current title"; try library.archive.save(note)
    let location = RecordingLocation(latitude: 1, longitude: 2, accuracyMeters: 3)

    try library.updateLocation(location, message: nil, for: note.id, activeRecordingID: note.id)

    note.location = location
    #expect(try locationMetadata(#require(NoteLibrary(directory: directory).notes.first)) == locationMetadata(note))
}

@MainActor @Test func locationUpdateAllowsCurrentLocalTranscriptionAndRetainsNewTitle() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let (library, note) = try locationFixture(directory)
    try library.transcribe([note.id], model: "fixture", language: "en")

    await library.process(key: { "fixture" }) { _, _, uploading in
        var current = uploading
        current.title = "Current upload title"; try library.archive.save(current)
        try library.updateLocation(nil, message: "Location unavailable", for: note.id, activeRecordingID: nil)
        current.locationStatus = "Location unavailable"
        #expect(try locationMetadata(#require(NoteLibrary(directory: directory).notes.first)) == locationMetadata(current))
        return TranscriptionResult(text: "Result", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
    }

    #expect(library.issue == nil && library.transcribingID == nil)
    let saved = try #require(NoteLibrary(directory: directory).notes.first)
    #expect(saved.status == "complete" && saved.title == "Current upload title")
    #expect(saved.locationStatus == "Location unavailable")
}

@MainActor @Test func locationUpdateReportsDeniedWriteWithoutChangingMetadataOrCache() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let (library, note) = try locationFixture(directory)
    defer {
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try! FileManager.default.removeItem(at: directory)
    }
    let original = try locationSnapshot(directory)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

    #expect(throws: (any Error).self) {
        try library.updateLocation(nil, message: "Location unavailable", for: note.id, activeRecordingID: nil)
    }

    #expect(try locationSnapshot(directory) == original)
    #expect(library.notes.first?.locationStatus == nil)
}
