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
                      .reading(loaded: 2, total: 3), .reading(loaded: 3, total: 3),
                      .recovering(recovered: 0, total: 2), .recovering(recovered: 1, total: 2), .recovering(recovered: 2, total: 2)])
    #expect(library.notes.first { $0.id == "a" }?.status == "interrupted")
    #expect(library.notes.first { $0.id == "b" }?.status == "failed")
    #expect(library.notes.first { $0.id == "c" }?.status == "complete")
    #expect(try String(contentsOf: archive.audioURL(note), encoding: .utf8) == "audio")
    #expect(try String(contentsOf: directory.appendingPathComponent("a.md"), encoding: .utf8) == "edited note")
    #expect(try NoteLibrary(directory: directory).notes.allSatisfy { $0.status != "recording" && $0.status != "transcribing" })
}

@MainActor @Test func malformedNoteStopsOpeningWithoutRecoveryOrPartialResults() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "recording")
    let original = try Data(contentsOf: directory.appendingPathComponent("a.json"))
    let broken = directory.appendingPathComponent("b.json")
    try Data("{".utf8).write(to: broken)
    _ = try fixture(archive, id: "c", status: "recording")
    var events: [NoteLoadProgress] = []
    do {
        _ = try await NoteLibrary.open(directory: directory) { events.append($0) }
        Issue.record("A partial library must never be returned")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .readNote)
        #expect(failure.url.lastPathComponent == broken.lastPathComponent)
        #expect(failure.url.deletingLastPathComponent().lastPathComponent == directory.lastPathComponent)
        #expect(failure.underlying is DecodingError)
        #expect(failure.technicalDetails.contains("b.json"))
    }
    #expect(events == [.opening, .reading(loaded: 0, total: 3), .reading(loaded: 1, total: 3)])
    #expect(try Data(contentsOf: directory.appendingPathComponent("a.json")) == original)
    _ = try fixture(archive, id: "b", status: "complete")
    let retried = try await NoteLibrary.open(directory: directory) { _ in }
    #expect(retried.notes.count == 3)
    #expect(retried.notes.first { $0.id == "a" }?.status == "interrupted")
}

@MainActor @Test func disappearedMetadataPreservesFileSystemErrorAndStopsAtThatNote() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    _ = try fixture(archive, id: "a", status: "complete")
    _ = try fixture(archive, id: "b", status: "complete")
    let missing = directory.appendingPathComponent("b.json")
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
    _ = try fixture(archive, id: "a", status: "recording")
    _ = try fixture(archive, id: "b", status: "transcribing")
    let metadata = directory.appendingPathComponent("b.json")
    let original = try Data(contentsOf: metadata)
    var mutationError: Error?
    var last = NoteLoadProgress.opening
    do {
        _ = try await NoteLibrary.open(directory: directory) { progress in
            last = progress
            if progress == .recovering(recovered: 1, total: 2) {
                do {
                    try FileManager.default.removeItem(at: metadata)
                    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
                } catch { mutationError = error }
            }
        }
        Issue.record("Failed recovery must not publish the library")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .recoverNote)
        #expect(failure.url.path == metadata.path)
        #expect(failure.technicalDetails.contains(NSCocoaErrorDomain))
    }
    #expect(mutationError == nil)
    #expect(last == .recovering(recovered: 1, total: 2))
    try FileManager.default.removeItem(at: metadata)
    try original.write(to: metadata)
    let retried = try await NoteLibrary.open(directory: directory) { _ in }
    #expect(retried.notes.first { $0.id == "a" }?.status == "interrupted")
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

@MainActor @Test func cancellationStopsTheWorkerBeforeRecovery() async throws {
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
