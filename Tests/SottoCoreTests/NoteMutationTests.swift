import Foundation
import Testing
@testable import SottoCore

private enum UserMutation: CaseIterable {
    case rename, saveText, delete, transcribe, replace

    @MainActor func apply(to library: NoteLibrary, note: RecordingRecord) throws {
        switch self {
        case .rename: try library.rename(note, to: "Local title", activeRecordingID: nil)
        case .saveText: try library.saveText("Local draft", for: note)
        case .delete: try library.delete([note.id])
        case .transcribe: try library.transcribe([note.id], model: "new-model", language: "es")
        case .replace: try library.useMachineTranscript(for: note)
        }
    }
}

@MainActor private func mutationFixture(_ directory: URL) throws -> (NoteLibrary, RecordingRecord) {
    let archive = try Archive(directory: directory)
    var note = try archive.newRecord(model: "original-model", language: "en", prompt: "", contextTerms: [])
    note.status = "complete"; note.title = "Cached title"
    try archive.save(note)
    try Data("Retained audio".utf8).write(to: archive.audioURL(note))
    try "Existing edits".write(to: directory.appendingPathComponent("\(note.id).md"), atomically: true, encoding: .utf8)
    try "Machine text".write(to: directory.appendingPathComponent("\(note.id).txt"), atomically: true, encoding: .utf8)
    try Data("{}".utf8).write(to: directory.appendingPathComponent("\(note.id).response.json"))
    return (try NoteLibrary(directory: directory), note)
}

private func mutationSnapshot(_ directory: URL) throws -> [String: Data] {
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
}

@MainActor @Test func freshMetadataRejectsUnavailableOrForeignActiveNotesBeforeMutatingFiles() throws {
    for scenario in ["deleted", "invalid", "wrong-id", "wrong-audio", "recording", "transcribing"] {
        for action in UserMutation.allCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try! FileManager.default.removeItem(at: directory) }
            let (library, note) = try mutationFixture(directory)
            let metadata = directory.appendingPathComponent("\(note.id).json")
            switch scenario {
            case "deleted": try FileManager.default.removeItem(at: metadata)
            case "invalid": try Data("{".utf8).write(to: metadata)
            default:
                var remote = note
                if scenario == "wrong-id" { remote.id = "another-note" }
                else if scenario == "wrong-audio" { remote.audioFile = "another-note.m4a" }
                else { remote.status = scenario }
                try JSONFile.write(remote, to: metadata)
            }
            let original = try mutationSnapshot(directory)

            #expect(throws: (any Error).self) { try action.apply(to: library, note: note) }

            #expect(try mutationSnapshot(directory) == original, "\(action) changed files with \(scenario) metadata")
        }
    }
}

@MainActor @Test func freshMetadataPreservesRemoteFieldsWhenRenamingOrRetranscribing() throws {
    for action in [UserMutation.rename, .transcribe] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let (library, note) = try mutationFixture(directory)
        var remote = note
        remote.title = "Remote title"; remote.generatedTitle = "Remote generated title"
        remote.model = "remote-model"; remote.language = "fr"
        remote.requestID = "remote-request"; remote.requestMilliseconds = 42
        remote.locationStatus = "Remote location information"
        try library.archive.save(remote)

        try action.apply(to: library, note: note)

        let saved = try #require(NoteLibrary(directory: directory).notes.first)
        #expect(saved.generatedTitle == remote.generatedTitle)
        #expect(saved.requestID == remote.requestID)
        #expect(saved.requestMilliseconds == remote.requestMilliseconds)
        #expect(saved.locationStatus == remote.locationStatus)
        if action == .rename {
            #expect(saved.title == "Local title")
            #expect(saved.model == remote.model && saved.language == remote.language)
        } else {
            #expect(saved.title == remote.title && saved.status == "queued")
            #expect(saved.model == "new-model" && saved.language == "es")
            #expect(saved.transcribedModel == remote.model)
        }
    }
}

@MainActor @Test func freshMetadataValidatesTheEntireBatchBeforeDeletingOrRetranscribing() throws {
    for action in [UserMutation.delete, .transcribe] {
        for scenario in ["deleted", "invalid", "recording"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try! FileManager.default.removeItem(at: directory) }
            let (library, first) = try mutationFixture(directory)
            var second = try library.archive.newRecord(model: "fixture", language: "en", prompt: "", contextTerms: [])
            second.status = "complete"
            try library.archive.save(second)
            try Data("Second audio".utf8).write(to: library.archive.audioURL(second))
            try library.reload()
            let metadata = directory.appendingPathComponent("\(second.id).json")
            switch scenario {
            case "deleted": try FileManager.default.removeItem(at: metadata)
            case "invalid": try Data("{".utf8).write(to: metadata)
            default: second.status = "recording"; try library.archive.save(second)
            }
            let original = try mutationSnapshot(directory)
            let ids: Set<String> = [first.id, second.id]

            #expect(throws: (any Error).self) {
                if action == .delete { try library.delete(ids) }
                else { try library.transcribe(ids, model: "new-model", language: "es") }
            }

            #expect(try mutationSnapshot(directory) == original)
        }
    }
}

@MainActor @Test func freshMetadataAllowsLocalRecordingRenameWithoutDroppingNewFields() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let note = try library.create(model: "fixture", language: "en")
    var current = note
    current.locationStatus = "Latest location information"
    try library.archive.save(current)

    try library.rename(note, to: "Local recording title", activeRecordingID: note.id)

    let saved = try #require(NoteLibrary(directory: directory).notes.first)
    #expect(saved.title == "Local recording title" && saved.status == "recording")
    #expect(saved.locationStatus == current.locationStatus)
}
