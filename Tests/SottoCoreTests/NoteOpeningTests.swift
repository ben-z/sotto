import Foundation
import Testing
@testable import SottoCore

private func fixture(_ archive: Archive, id: String, status: String) throws -> RecordingRecord {
    var record = RecordingRecord(id: id, model: "whisper-large-v3-turbo", language: "en", prompt: "", contextTerms: [], audioFile: "\(id).m4a")
    record.status = status
    try archive.save(record)
    return record
}

@MainActor @Test func openingReportsValidatedCountsAndRecoversBeforeReturning() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    let note = try fixture(archive, id: "a", status: "recording")
    try Data("audio".utf8).write(to: archive.audioURL(note))
    try Data("edited note".utf8).write(to: directory.appendingPathComponent("a.md"))
    _ = try fixture(archive, id: "b", status: "transcribing")
    _ = try fixture(archive, id: "c", status: "complete")
    try Data("not metadata".utf8).write(to: directory.appendingPathComponent("c.response.json"))
    var events: [NoteLoadProgress] = []
    let library = try await NoteLibrary.open(directory: directory) { events.append($0) }
    #expect(events == [.opening, .reading(loaded: 0, total: 3), .reading(loaded: 1, total: 3),
                      .reading(loaded: 2, total: 3), .reading(loaded: 3, total: 3)])
    #expect(library.notes.first { $0.id == "a" }?.status == "interrupted")
    #expect(library.notes.first { $0.id == "b" }?.status == "failed")
    #expect(library.notes.first { $0.id == "c" }?.status == "complete")
    #expect(try String(contentsOf: archive.audioURL(note), encoding: .utf8) == "audio")
    #expect(try String(contentsOf: directory.appendingPathComponent("a.md"), encoding: .utf8) == "edited note")
    #expect(try NoteLibrary(directory: directory).notes.allSatisfy { $0.status != "recording" && $0.status != "transcribing" })
}

@MainActor @Test func malformedNoteStopsLoadingAndKeepsEarlierPublishedNotes() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "recording")
    let original = try Data(contentsOf: directory.appendingPathComponent("a.json"))
    let broken = directory.appendingPathComponent("b.json")
    try Data("{".utf8).write(to: broken)
    _ = try fixture(archive, id: "c", status: "recording")
    let library = NoteLibrary(archive: archive)
    var events: [NoteLoadProgress] = []
    do {
        try await library.loadHistory { events.append($0) }
        Issue.record("An unreadable note must fail the load")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .readNote)
        #expect(failure.url.lastPathComponent == broken.lastPathComponent)
        #expect(failure.url.deletingLastPathComponent().lastPathComponent == directory.lastPathComponent)
        #expect(failure.underlying is DecodingError)
        #expect(failure.technicalDetails.contains("b.json"))
    }
    #expect(events == [.reading(loaded: 0, total: 3), .reading(loaded: 1, total: 3)])
    #expect(library.notes.map(\.id) == ["c"])
    #expect(library.notes.first?.status == "interrupted")
    #expect(try Data(contentsOf: directory.appendingPathComponent("a.json")) == original)
    _ = try fixture(archive, id: "b", status: "complete")
    try await library.loadHistory { _ in }
    #expect(library.notes.count == 3)
    #expect(library.notes.first { $0.id == "a" }?.status == "interrupted")
}

@MainActor @Test func disappearedMetadataPreservesFileSystemErrorAndStopsAtThatNote() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "complete")
    _ = try fixture(archive, id: "b", status: "complete")
    let missing = directory.appendingPathComponent("a.json")
    var mutationError: Error?
    var last = NoteLoadProgress.opening
    do {
        _ = try await NoteLibrary.open(directory: directory) { progress in
            last = progress
            if progress == .reading(loaded: 1, total: 2) {
                do { try FileManager.default.removeItem(at: missing) }
                catch { mutationError = error }
            }
        }
        Issue.record("A disappeared file must fail the load")
    } catch let failure as NoteLoadFailure {
        #expect(failure.url.lastPathComponent == missing.lastPathComponent)
        #expect(failure.url.deletingLastPathComponent().lastPathComponent == directory.lastPathComponent)
        #expect((failure.underlying as NSError).domain == NSCocoaErrorDomain)
        #expect(failure.technicalDetails.contains(NSCocoaErrorDomain))
        #expect(failure.technicalDetails.contains(NSPOSIXErrorDomain))
    }
    #expect(mutationError == nil)
    #expect(last == .reading(loaded: 1, total: 2))
}

@MainActor @Test func failedRecoveryWriteStopsOpeningAndCanBeRetried() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "b", status: "transcribing")
    let metadata = directory.appendingPathComponent("b.json")
    let original = try Data(contentsOf: metadata)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    var last = NoteLoadProgress.opening
    do {
        let library = NoteLibrary(archive: archive)
        try await library.loadHistory { last = $0 }
        Issue.record("Failed recovery must not publish the library")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .recoverNote)
        #expect(failure.url.path == metadata.path)
        #expect(failure.technicalDetails.contains(NSCocoaErrorDomain))
    }
    #expect(last == .reading(loaded: 0, total: 1))
    #expect(try Data(contentsOf: metadata) == original)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let retried = try await NoteLibrary.open(directory: directory) { _ in }
    #expect(retried.notes.first { $0.id == "b" }?.status == "failed")
}

@MainActor @Test func emptyFolderFinishesWithoutRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var events: [NoteLoadProgress] = []
    let library = try await NoteLibrary.open(directory: directory) { events.append($0) }
    #expect(library.notes.isEmpty)
    #expect(events == [.opening, .reading(loaded: 0, total: 0)])
}

@MainActor @Test func recordingCreatedDuringHistoryLoadSurvivesRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "complete")
    _ = try fixture(archive, id: "b", status: "recording")
    let library = NoteLibrary(archive: archive)
    var active: RecordingRecord?
    try await library.loadHistory { progress in
        if progress == .reading(loaded: 1, total: 2) {
            do { active = try library.create(model: "fixture", language: "en") }
            catch { Issue.record("Could not start a recording while history loaded: \(error)") }
        }
    }
    let recording = try #require(active)
    #expect(library.notes.first { $0.id == recording.id }?.status == "recording")
    #expect(library.notes.first { $0.id == "b" }?.status == "interrupted")
    #expect(library.notes.count == 3)
    let stored = try Data(contentsOf: directory.appendingPathComponent("\(recording.id).json"))
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(RecordingRecord.self, from: stored).status == "recording")
}

@MainActor @Test func historyPublishesEachNoteBeforeReportingItLoaded() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    for (offset, id) in ["a", "b", "c"].enumerated() {
        var note = try fixture(archive, id: id, status: "recording")
        note.startedAt = Date(timeIntervalSince1970: Double(offset))
        try archive.save(note)
    }
    let library = NoteLibrary(archive: archive)
    var snapshots: [[String]] = []
    try await library.loadHistory { progress in
        if case .reading(let loaded, _) = progress {
            #expect(library.notes.count == loaded)
            #expect(library.notes.allSatisfy { $0.status == "interrupted" })
            snapshots.append(library.notes.map(\.id))
        }
    }
    #expect(snapshots == [[], ["c"], ["c", "b"], ["c", "b", "a"]])
}

@MainActor @Test func publishedHistoryCanBeEditedAndDeletedWhileLoading() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    for id in ["a", "b", "c"] { _ = try fixture(archive, id: id, status: "complete") }
    let library = NoteLibrary(archive: archive)
    var mutationError: Error?
    try await library.loadHistory { progress in
        do {
            if progress == .reading(loaded: 1, total: 3) {
                let note = try #require(library.notes.first { $0.id == "c" })
                try library.rename(note, to: "Edited during loading")
            }
            if progress == .reading(loaded: 2, total: 3) { try library.delete(["b"]) }
        } catch { mutationError = error }
    }
    #expect(mutationError == nil)
    #expect(library.notes.count == 2)
    #expect(library.notes.first { $0.id == "c" }?.title == "Edited during loading")
    #expect(!library.notes.contains { $0.id == "b" })
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("b.json").path))
    try await library.loadHistory { progress in
        if progress == .reading(loaded: 0, total: 2) {
            do { try library.delete(["a"]) }
            catch { mutationError = error }
        }
    }
    #expect(mutationError == nil)
    #expect(library.notes.map(\.id) == ["c"])
    #expect(library.notes.first?.title == "Edited during loading")
}

@MainActor @Test func historyDoesNotReadAudioOrTranscriptForNotesWithSavedTitles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    var note = try fixture(archive, id: "a", status: "complete")
    note.generatedTitle = "Saved title"
    try archive.save(note)
    for ext in ["m4a", "txt", "md"] {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("a.\(ext)"), withIntermediateDirectories: false)
    }
    try Data("not metadata".utf8).write(to: directory.appendingPathComponent("a.response.json"))
    let library = NoteLibrary(archive: archive)
    try await library.loadHistory { _ in }
    #expect(library.notes.first?.displayTitle == "Saved title")
    #expect(throws: (any Error).self) { try library.text(for: note) }
}

@MainActor @Test func corruptHistoryDoesNotDiscardNewRecording() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    try Data("{".utf8).write(to: directory.appendingPathComponent("a.json"))
    let library = NoteLibrary(archive: archive)
    let recording = try library.create(model: "fixture", language: "en")
    await #expect(throws: NoteLoadFailure.self) { try await library.loadHistory { _ in } }
    #expect(library.notes.map(\.id) == [recording.id])
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(recording.id).json").path))
}

@MainActor @Test func retryStillValidatesMetadataForAlreadyVisibleNotes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "complete")
    let library = NoteLibrary(archive: archive)
    try await library.loadHistory { _ in }
    try Data("{".utf8).write(to: directory.appendingPathComponent("a.json"))
    await #expect(throws: NoteLoadFailure.self) { try await library.loadHistory { _ in } }
    #expect(library.notes.map(\.id) == ["a"])
}

@MainActor @Test func unavailableFolderPreservesTheUnderlyingError() async throws {
    let file = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data().write(to: file)
    do {
        _ = try await NoteLibrary.open(directory: file) { _ in }
        Issue.record("A regular file cannot be opened as a library folder")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .openFolder)
        #expect(failure.url == file)
        #expect(failure.technicalDetails.contains(NSCocoaErrorDomain))
    }
}

@MainActor @Test func invalidMetadataDoesNotCountAsALoadedNote() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    var note = try fixture(archive, id: "a", status: "complete")
    note.audioFile = "another-note.m4a"
    try archive.save(note)
    var last = NoteLoadProgress.opening
    do {
        _ = try await NoteLibrary.open(directory: directory) { last = $0 }
        Issue.record("Inconsistent note identity must fail validation")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .readNote)
        #expect(failure.technicalDetails.contains("Invalid note metadata"))
    }
    #expect(last == .reading(loaded: 0, total: 1))
}

@MainActor @Test func unreadableTitleSourceReportsTheTranscriptPath() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "complete")
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("a.txt"), withIntermediateDirectories: false)
    var last = NoteLoadProgress.opening
    do {
        _ = try await NoteLibrary.open(directory: directory) { last = $0 }
        Issue.record("Failed title reads must not be treated as a complete note")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .readNote)
        #expect(failure.url.lastPathComponent == "a.txt")
    }
    #expect(last == .reading(loaded: 0, total: 1))
}

@MainActor @Test func cancellationStopsBeforeReadingTheNextNote() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "recording")
    _ = try fixture(archive, id: "b", status: "recording")
    let original = try Data(contentsOf: directory.appendingPathComponent("a.json"))
    var events: [NoteLoadProgress] = []
    var task: Task<NoteLibrary, Error>?
    task = Task {
        try await NoteLibrary.open(directory: directory) { progress in
            events.append(progress)
            if progress == .reading(loaded: 1, total: 2) { task?.cancel() }
        }
    }
    let running = try #require(task)
    do {
        _ = try await running.value
        Issue.record("Cancellation must not publish a library")
    } catch is CancellationError { }
    #expect(events == [.opening, .reading(loaded: 0, total: 2), .reading(loaded: 1, total: 2)])
    #expect(try Data(contentsOf: directory.appendingPathComponent("a.json")) == original)
}
