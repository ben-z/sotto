import Foundation
import Testing
@testable import SottoCore

private func fixture(_ archive: Archive, id: String, status: String) throws -> RecordingRecord {
    var record = RecordingRecord(id: id, model: "whisper-large-v3-turbo", language: "en", prompt: "", contextTerms: [], audioFile: "\(id).m4a")
    record.status = status
    try archive.save(record)
    return record
}

@MainActor @Test func openingAndReloadingLeaveExistingMetadataUnchanged() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    let note = try fixture(archive, id: "a", status: "recording")
    try Data("audio".utf8).write(to: archive.audioURL(note))
    try Data("edited note".utf8).write(to: directory.appendingPathComponent("a.md"))
    _ = try fixture(archive, id: "b", status: "transcribing")
    _ = try fixture(archive, id: "c", status: "complete")
    try Data("not metadata".utf8).write(to: directory.appendingPathComponent("c.response.json"))
    let originals = try ["a", "b", "c"].map { try Data(contentsOf: directory.appendingPathComponent("\($0).json")) }
    var events: [NoteLoadProgress] = []
    let library = try await NoteLibrary.open(directory: directory, pageSize: Configuration.historyPageSize) { events.append($0) }
    #expect(events == [.opening, .reading(loaded: 0, total: 3), .reading(loaded: 1, total: 3),
                      .reading(loaded: 2, total: 3), .reading(loaded: 3, total: 3)])
    #expect(library.notes.first { $0.id == "a" }?.status == "recording")
    #expect(library.notes.first { $0.id == "b" }?.status == "transcribing")
    #expect(library.notes.first { $0.id == "c" }?.status == "complete")
    #expect(try String(contentsOf: archive.audioURL(note), encoding: .utf8) == "audio")
    #expect(try String(contentsOf: directory.appendingPathComponent("a.md"), encoding: .utf8) == "edited note")
    try library.reload()
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in }
    let reopened = try NoteLibrary(directory: directory)
    #expect(reopened.notes.first { $0.id == "a" }?.status == "recording")
    for (id, original) in zip(["a", "b", "c"], originals) {
        #expect(try Data(contentsOf: directory.appendingPathComponent("\(id).json")) == original)
    }
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
        try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { events.append($0) }
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
    #expect(library.notes.first?.status == "recording")
    #expect(try Data(contentsOf: directory.appendingPathComponent("a.json")) == original)
    _ = try fixture(archive, id: "b", status: "complete")
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in }
    #expect(library.notes.count == 3)
    #expect(library.notes.first { $0.id == "a" }?.status == "recording")
}

@MainActor @Test func metadataDeletedRemotelyAfterListingDoesNotBlockThePage() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "complete")
    _ = try fixture(archive, id: "b", status: "complete")
    let missing = directory.appendingPathComponent("a.json")
    var mutationError: Error?
    var last = NoteLoadProgress.opening
    let library = try await NoteLibrary.open(directory: directory, pageSize: Configuration.historyPageSize) { progress in
        last = progress
        if progress == .reading(loaded: 1, total: 2) {
            do { try FileManager.default.removeItem(at: missing) }
            catch { mutationError = error }
        }
    }
    #expect(mutationError == nil)
    #expect(last == .reading(loaded: 2, total: 2))
    #expect(library.notes.map(\.id) == ["b"])
    #expect(!library.hasMoreHistory)
}

@MainActor @Test func historyLoadsWithoutWritingAndExplicitRecoveryReportsDeniedWrite() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "b", status: "transcribing")
    let metadata = directory.appendingPathComponent("b.json")
    let original = try Data(contentsOf: metadata)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    var last = NoteLoadProgress.opening
    let library = NoteLibrary(archive: archive)
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { last = $0 }
    #expect(last == .reading(loaded: 1, total: 1))
    do {
        try library.recover("b", activeRecordingID: nil)
        Issue.record("A denied recovery write must be reported")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .recoverNote)
        #expect(failure.url.path == metadata.path)
        #expect(failure.technicalDetails.contains(NSCocoaErrorDomain))
        #expect(failure.localizedDescription.contains(failure.underlying.localizedDescription))
    }
    #expect(library.notes.first?.status == "transcribing")
    #expect(try Data(contentsOf: metadata) == original)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try library.recover("b", activeRecordingID: nil)
    #expect(library.notes.first?.status == "failed")
}

@MainActor @Test func emptyFolderFinishesWithoutRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var events: [NoteLoadProgress] = []
    let library = try await NoteLibrary.open(directory: directory, pageSize: Configuration.historyPageSize) { events.append($0) }
    #expect(library.notes.isEmpty)
    #expect(events == [.opening, .reading(loaded: 0, total: 0)])
}

@MainActor @Test func recordingCreatedDuringHistoryLoadSurvives() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "complete")
    _ = try fixture(archive, id: "b", status: "recording")
    let library = NoteLibrary(archive: archive)
    var active: RecordingRecord?
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { progress in
        if progress == .reading(loaded: 1, total: 2) {
            do { active = try library.create(model: "fixture", language: "en") }
            catch { Issue.record("Could not start a recording while history loaded: \(error)") }
        }
    }
    let recording = try #require(active)
    #expect(library.notes.first { $0.id == recording.id }?.status == "recording")
    #expect(library.notes.first { $0.id == "b" }?.status == "recording")
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
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { progress in
        if case .reading(let loaded, _) = progress {
            #expect(library.notes.count == loaded)
            #expect(library.notes.allSatisfy { $0.status == "recording" })
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
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { progress in
        do {
            if progress == .reading(loaded: 1, total: 3) {
                let note = try #require(library.notes.first { $0.id == "c" })
                try library.rename(note, to: "Edited during loading", activeRecordingID: nil)
            }
            if progress == .reading(loaded: 2, total: 3) { try library.delete(["b"]) }
        } catch { mutationError = error }
    }
    #expect(mutationError == nil)
    #expect(library.notes.count == 2)
    #expect(library.notes.first { $0.id == "c" }?.title == "Edited during loading")
    #expect(!library.notes.contains { $0.id == "b" })
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("b.json").path))
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { progress in
        if progress == .reading(loaded: 0, total: 2) {
            do { try library.delete(["a"]) }
            catch { mutationError = error }
        }
    }
    #expect(mutationError == nil)
    #expect(library.notes.map(\.id) == ["c"])
    #expect(library.notes.first?.title == "Edited during loading")
}

@MainActor @Test func historyReadsOnlyMetadataIncludingUntitledLegacyNotes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    var generated = try fixture(archive, id: "a", status: "complete")
    generated.generatedTitle = "Saved title"
    var renamed = try fixture(archive, id: "b", status: "complete")
    renamed.title = "Custom title"
    let legacy = try fixture(archive, id: "c", status: "complete")
    let records = [generated, renamed, legacy]
    for note in records {
        try archive.save(note)
        for ext in ["m4a", "txt", "md"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("\(note.id).\(ext)"), withIntermediateDirectories: false)
        }
    }
    try Data("not metadata".utf8).write(to: directory.appendingPathComponent("a.response.json"))
    let library = NoteLibrary(archive: archive)
    let originals = try records.map { try Data(contentsOf: directory.appendingPathComponent("\($0.id).json")) }
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in }
    try library.reload()
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in }
    #expect(Set(library.notes.map(\.displayTitle)) == ["Saved title", "Custom title", "Voice note"])
    for (note, original) in zip(records, originals) {
        #expect(throws: (any Error).self) { try library.text(for: note) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("\(note.id).json")) == original)
    }
}

@MainActor @Test func corruptHistoryDoesNotDiscardNewRecording() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    try Data("{".utf8).write(to: directory.appendingPathComponent("a.json"))
    let library = NoteLibrary(archive: archive)
    let recording = try library.create(model: "fixture", language: "en")
    await #expect(throws: NoteLoadFailure.self) { try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in } }
    #expect(library.notes.map(\.id) == [recording.id])
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(recording.id).json").path))
}

@MainActor @Test func clearingLegacyTitleReadsTranscriptOnlyWhenRequested() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    var note = try fixture(archive, id: "a", status: "complete")
    note.title = "Custom title"
    try archive.save(note)
    let transcript = directory.appendingPathComponent("a.txt")
    try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: false)
    let library = NoteLibrary(archive: archive)
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in }
    #expect(throws: NoteLoadFailure.self) { try library.rename(note, to: " ", activeRecordingID: nil) }
    #expect(library.notes.first?.displayTitle == "Custom title")
    try FileManager.default.removeItem(at: transcript)
    try "The original transcript title".write(to: transcript, atomically: true, encoding: .utf8)
    try library.rename(note, to: " ", activeRecordingID: nil)
    #expect(library.notes.first?.displayTitle == "The original transcript title")
    #expect(try NoteLibrary(directory: directory).notes.first?.displayTitle == "The original transcript title")
}

@MainActor @Test func retryStillValidatesMetadataForAlreadyVisibleNotes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "complete")
    let library = NoteLibrary(archive: archive)
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in }
    try Data("{".utf8).write(to: directory.appendingPathComponent("a.json"))
    await #expect(throws: NoteLoadFailure.self) { try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in } }
    #expect(library.notes.map(\.id) == ["a"])
}

@MainActor @Test func historyRefreshReconcilesExternalAdditionsEditsAndDeletions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    var edited = try fixture(archive, id: "a", status: "complete")
    _ = try fixture(archive, id: "b", status: "complete")
    let library = try NoteLibrary(directory: directory)
    edited.title = "Changed on another device"
    edited.startedAt = Date(timeIntervalSince1970: 1)
    try archive.save(edited)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("b.json"))
    var added = try fixture(archive, id: "c", status: "queued")
    added.startedAt = Date(timeIntervalSince1970: 2)
    try archive.save(added)
    let originals = try ["a", "c"].map { try Data(contentsOf: directory.appendingPathComponent("\($0).json")) }
    for _ in 0..<2 {
        try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in }
        #expect(library.notes.map(\.id) == ["c", "a"])
        #expect(library.notes.last?.title == edited.title)
        #expect(library.notes.first?.status == "queued")
    }
    for (id, original) in zip(["a", "c"], originals) {
        #expect(try Data(contentsOf: directory.appendingPathComponent("\(id).json")) == original)
    }
}

@MainActor @Test func historyRefreshPreservesMutationsMadeDuringThePass() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    let edited = try fixture(archive, id: "a", status: "complete")
    _ = try fixture(archive, id: "b", status: "complete")
    let recovered = try fixture(archive, id: "c", status: "recording")
    let library = try NoteLibrary(directory: directory)
    var created: RecordingRecord?
    var mutationError: Error?
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { progress in
        guard progress == .reading(loaded: 0, total: 3) else { return }
        do {
            try library.rename(edited, to: "Local title", activeRecordingID: nil)
            try library.delete(["b"])
            try library.recover("c", activeRecordingID: nil)
            created = try library.create(model: "fixture", language: "en")
            // A late remote copy must not replace changes made during this pass.
            try archive.save(edited)
            try archive.save(recovered)
        } catch { mutationError = error }
    }
    #expect(mutationError == nil)
    #expect(library.notes.first { $0.id == "a" }?.title == "Local title")
    #expect(library.notes.first { $0.id == "c" }?.status == "interrupted")
    #expect(!library.notes.contains { $0.id == "b" })
    #expect(library.notes.contains { $0.id == created?.id })
    #expect(library.notes.count == 3)
}

@MainActor @Test func historyRefreshProtectsOnlyTheActualLocalRecording() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let recording = try library.create(model: "fixture", language: "en")
    var foreign = try fixture(library.archive, id: "a", status: "recording")
    try await library.loadHistory(activeRecordingID: recording.id, pageSize: Configuration.historyPageSize) { _ in }
    foreign.status = "complete"; foreign.title = "Finished elsewhere"
    try library.archive.save(foreign)
    let metadata = directory.appendingPathComponent("\(recording.id).json")
    try FileManager.default.removeItem(at: metadata)
    try await library.loadHistory(activeRecordingID: recording.id, pageSize: Configuration.historyPageSize) { _ in }
    #expect(library.notes.first { $0.id == recording.id }?.status == "recording")
    #expect(library.notes.first { $0.id == foreign.id }?.title == "Finished elsewhere")
    var stale = recording; stale.status = "cancelled"
    try library.archive.save(stale)
    try await library.loadHistory(activeRecordingID: recording.id, pageSize: Configuration.historyPageSize) { _ in }
    #expect(library.notes.first { $0.id == recording.id }?.status == "recording")
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in }
    #expect(library.notes.first { $0.id == recording.id }?.status == "cancelled")
}

@MainActor @Test func historyRefreshPreservesAnAlreadyActiveUpload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try NoteLibrary(directory: directory)
    let note = try library.create(model: "fixture", language: "en")
    try Data([1]).write(to: library.archive.audioURL(note))
    try library.queue(note)
    await library.process(key: { "fixture" }) { _, _, uploading in
        #expect(library.transcribingID == note.id)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(note.id).json"))
        try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in }
        #expect(library.notes.first?.status == "transcribing")
        try library.archive.save(uploading)
        return TranscriptionResult(text: "Completed while refreshing", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
    }
    #expect(library.notes.first?.status == "complete")
    #expect(library.issue == nil)
}

@MainActor @Test func failedAndCancelledRefreshesDoNotPruneAbsentRows() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    for id in ["a", "b", "c"] { _ = try fixture(archive, id: id, status: "complete") }
    let library = try NoteLibrary(directory: directory)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("a.json"))
    try Data("{".utf8).write(to: directory.appendingPathComponent("b.json"))
    await #expect(throws: NoteLoadFailure.self) { try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in } }
    #expect(Set(library.notes.map(\.id)) == ["a", "b", "c"])
    _ = try fixture(archive, id: "b", status: "complete")
    var task: Task<Void, Error>?
    task = Task {
        try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { progress in
            if progress == .reading(loaded: 2, total: 2) { task?.cancel() }
        }
    }
    let running = try #require(task)
    await #expect(throws: CancellationError.self) { try await running.value }
    #expect(Set(library.notes.map(\.id)) == ["a", "b", "c"])
    try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize) { _ in }
    #expect(Set(library.notes.map(\.id)) == ["b", "c"])
}

@MainActor @Test func unavailableFolderPreservesTheUnderlyingError() async throws {
    let file = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data().write(to: file)
    do {
        _ = try await NoteLibrary.open(directory: file, pageSize: Configuration.historyPageSize) { _ in }
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
        _ = try await NoteLibrary.open(directory: directory, pageSize: Configuration.historyPageSize) { last = $0 }
        Issue.record("Inconsistent note identity must fail validation")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .readNote)
        #expect(failure.technicalDetails.contains("Invalid note metadata"))
    }
    #expect(last == .reading(loaded: 0, total: 1))
}

@MainActor @Test func unreadableLegacyTranscriptFailsOnlyOnExplicitRead() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "complete")
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("a.txt"), withIntermediateDirectories: false)
    var last = NoteLoadProgress.opening
    let library = try await NoteLibrary.open(directory: directory, pageSize: Configuration.historyPageSize) { last = $0 }
    let note = try #require(library.notes.first)
    #expect(note.displayTitle == "Voice note")
    #expect(throws: (any Error).self) { try library.text(for: note) }
    do {
        try library.rename(note, to: "", activeRecordingID: nil)
        Issue.record("Explicit title derivation must report an unreadable transcript")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .readNote)
        #expect(failure.url.lastPathComponent == "a.txt")
    }
    #expect(last == .reading(loaded: 1, total: 1))
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
        try await NoteLibrary.open(directory: directory, pageSize: Configuration.historyPageSize) { progress in
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
