import Foundation
import Testing
@testable import SottoCore

private func paginatedFixture(_ archive: Archive, second: Int) throws -> RecordingRecord {
    let date = Date(timeIntervalSince1970: 1_577_836_800 + Double(second))
    let id = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-") + "-fixture"
    var note = RecordingRecord(id: id, model: "fixture", language: "en", prompt: "", contextTerms: [], audioFile: "\(id).m4a")
    note.startedAt = date; note.status = "complete"; note.title = "Note \(second)"
    try archive.save(note)
    return note
}

@MainActor @Test func historyOpensOnlyTheFirstPageAndRetriesUnreadableOlderMetadata() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    let records = try (1...4).map { try paginatedFixture(archive, second: $0 * 10) }
    let broken = directory.appendingPathComponent("\(records[0].id).json")
    try Data("{".utf8).write(to: broken)
    var events: [NoteLoadProgress] = []

    let library = try await NoteLibrary.open(directory: directory, pageSize: 2) { events.append($0) }

    #expect(library.notes.map(\.id) == [records[3].id, records[2].id])
    #expect(library.hasMoreHistory)
    #expect(events == [.opening, .reading(loaded: 0, total: 2), .reading(loaded: 1, total: 2), .reading(loaded: 2, total: 2)])
    do {
        try await library.loadMoreHistory(activeRecordingID: nil, pageSize: 2) { _ in }
        Issue.record("Unreadable older metadata must fail its page")
    } catch let failure as NoteLoadFailure {
        #expect(failure.operation == .readNote)
        #expect(failure.url.lastPathComponent == broken.lastPathComponent)
        #expect(failure.url.deletingLastPathComponent().resolvingSymlinksInPath().path ==
                broken.deletingLastPathComponent().resolvingSymlinksInPath().path)
        #expect(failure.underlying is DecodingError)
    }
    #expect(library.notes.map(\.id) == [records[3].id, records[2].id, records[1].id])
    #expect(library.hasMoreHistory)
    #expect(try Data(contentsOf: broken) == Data("{".utf8))
    var changed = records[1]; changed.title = "Changed after the failed page"
    try archive.save(changed)
    try archive.save(records[0])

    try await library.loadMoreHistory(activeRecordingID: nil, pageSize: 2) { _ in }

    #expect(library.notes.map(\.id) == records.reversed().map(\.id))
    #expect(library.notes.first { $0.id == changed.id }?.title == changed.title)
    #expect(!library.hasMoreHistory)
}

@MainActor @Test func historyFilenameCursorSurvivesRemoteInsertionsAndDeletionOfItsBoundary() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    let records = try (1...6).map { try paginatedFixture(archive, second: $0 * 10) }
    let library = try await NoteLibrary.open(directory: directory, pageSize: 2) { _ in }
    try FileManager.default.removeItem(at: directory.appendingPathComponent("\(records[4].id).json"))
    let arrivals = try [70, 80].map { try paginatedFixture(archive, second: $0) }

    try await library.loadMoreHistory(activeRecordingID: nil, pageSize: 2) { _ in }

    #expect(library.notes.map(\.id) == [records[5].id, records[3].id, records[2].id])
    #expect(!library.notes.contains { note in arrivals.contains { $0.id == note.id } })
    #expect(library.hasMoreHistory)
    try await library.loadMoreHistory(activeRecordingID: nil, pageSize: 2) { _ in }
    #expect(library.notes.map(\.id) == [records[5].id, records[3].id, records[2].id, records[1].id, records[0].id])
    #expect(!library.hasMoreHistory)
}

@MainActor @Test func historyRefreshRereadsTheVisitedFilenamePrefixIncludingNewArrivals() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    let records = try (1...8).map { try paginatedFixture(archive, second: $0 * 10) }
    let library = try await NoteLibrary.open(directory: directory, pageSize: 2) { _ in }
    try await library.loadMoreHistory(activeRecordingID: nil, pageSize: 2) { _ in }
    var changed = records[5]; changed.title = "Changed on another device"
    try archive.save(changed)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("\(records[6].id).json"))
    let newest = try paginatedFixture(archive, second: 90)
    let inserted = try paginatedFixture(archive, second: 55)
    let unread = try paginatedFixture(archive, second: 35)
    try Data("{".utf8).write(to: directory.appendingPathComponent("\(unread.id).json"))
    var progress: [NoteLoadProgress] = []

    try await library.loadHistory(activeRecordingID: nil, pageSize: 2) { progress.append($0) }

    #expect(library.notes.map(\.id) == [newest.id, records[7].id, changed.id, inserted.id, records[4].id])
    #expect(library.notes.first { $0.id == changed.id }?.title == changed.title)
    #expect(progress.first == .reading(loaded: 0, total: 5))
    #expect(progress.last == .reading(loaded: 5, total: 5))
    #expect(library.hasMoreHistory)
}

@MainActor @Test func cancelledHistoryPageRetainsRowsAndRetriesFromItsUncommittedCursor() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    let records = try (1...6).map { try paginatedFixture(archive, second: $0 * 10) }
    let library = try await NoteLibrary.open(directory: directory, pageSize: 2) { _ in }
    var task: Task<Void, Error>?
    task = Task {
        try await library.loadMoreHistory(activeRecordingID: nil, pageSize: 2) { progress in
            if progress == .reading(loaded: 1, total: 2) { task?.cancel() }
        }
    }
    let running = try #require(task)
    await #expect(throws: CancellationError.self) { try await running.value }
    #expect(library.notes.map(\.id) == [records[5].id, records[4].id, records[3].id])
    #expect(library.hasMoreHistory)
    var changed = records[3]; changed.title = "Reread after cancellation"
    try archive.save(changed)

    try await library.loadMoreHistory(activeRecordingID: nil, pageSize: 2) { _ in }

    #expect(library.notes.map(\.id) == [records[5].id, records[4].id, changed.id, records[2].id])
    #expect(library.notes.first { $0.id == changed.id }?.title == changed.title)
    try await library.loadMoreHistory(activeRecordingID: nil, pageSize: 2) { _ in }
    #expect(library.notes.map(\.id) == records.reversed().map(\.id))
    #expect(!library.hasMoreHistory)
}

@MainActor @Test func localEditsDeletionAndNewRecordingSurviveAnOlderHistoryPage() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    let records = try (1...4).map { try paginatedFixture(archive, second: $0 * 10) }
    let library = try await NoteLibrary.open(directory: directory, pageSize: 2) { _ in }
    var created: RecordingRecord?
    var mutationError: Error?

    try await library.loadMoreHistory(activeRecordingID: nil, pageSize: 2) { progress in
        guard progress == .reading(loaded: 1, total: 2) else { return }
        do {
            let published = try #require(library.notes.first { $0.id == records[1].id })
            try library.rename(published, to: "Edited during paging", activeRecordingID: nil)
            try library.delete([records[3].id])
            created = try library.create(model: "fixture", language: "en")
            // A late remote copy must not replace an edit made during this page.
            try archive.save(records[1])
        } catch { mutationError = error }
    }

    #expect(mutationError == nil)
    let recording = try #require(created)
    #expect(library.notes.map(\.id) == [recording.id, records[2].id, records[1].id, records[0].id])
    #expect(library.notes.first { $0.id == records[1].id }?.title == "Edited during paging")
    #expect(library.notes.first { $0.id == recording.id }?.status == "recording")
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(records[3].id).json").path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(recording.id).json").path))
    #expect(!library.hasMoreHistory)
}

@MainActor @Test func pagingProtectsTheActualLocalRecordingFromRemoteChangesAndDeletion() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    let records = try (1...6).map { try paginatedFixture(archive, second: $0 * 10) }
    let library = try await NoteLibrary.open(directory: directory, pageSize: 2) { _ in }
    var recording = records[3]; recording.status = "recording"; recording.title = "Local recording"
    try library.save(recording)
    var remote = recording; remote.status = "cancelled"; remote.title = "Remote stale copy"
    try archive.save(remote)

    try await library.loadMoreHistory(activeRecordingID: recording.id, pageSize: 2) { _ in }

    #expect(library.notes.first { $0.id == recording.id }?.status == "recording")
    #expect(library.notes.first { $0.id == recording.id }?.title == recording.title)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("\(recording.id).json"))
    try await library.loadMoreHistory(activeRecordingID: recording.id, pageSize: 2) { _ in }
    #expect(library.notes.first { $0.id == recording.id }?.status == "recording")
    #expect(!library.hasMoreHistory)
    try await library.loadHistory(activeRecordingID: nil, pageSize: 2) { _ in }
    #expect(!library.notes.contains { $0.id == recording.id })
}

@MainActor @Test func pagingPreservesAnAlreadyActiveUploadWhoseMetadataDisappears() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try! FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    let records = try (1...4).map { try paginatedFixture(archive, second: $0 * 10) }
    let library = try await NoteLibrary.open(directory: directory, pageSize: 2) { _ in }
    let note = records[3]
    try Data([1]).write(to: archive.audioURL(note))
    try library.transcribe([note.id], model: "fixture", language: "en")

    await library.process(ids: [note.id], key: { "fixture" }) { _, _, uploading in
        #expect(library.transcribingID == note.id)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(note.id).json"))
        try await library.loadMoreHistory(activeRecordingID: nil, pageSize: 2) { _ in }
        #expect(library.notes.first { $0.id == note.id }?.status == "transcribing")
        try archive.save(uploading)
        return TranscriptionResult(text: "Completed while paging", rawResponse: Data("{}".utf8), milliseconds: 1, requestID: nil)
    }

    #expect(library.issue == nil)
    #expect(library.notes.first { $0.id == note.id }?.status == "complete")
    #expect(library.notes.count == 4 && !library.hasMoreHistory)
}

@MainActor @Test func historyDoesNotSkipUnreadableEntriesThatStillAppearInTheFolder() async throws {
    for replacement in ["directory", "dangling-link"] {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let archive = try Archive(directory: directory)
        let records = try [10, 20].map { try paginatedFixture(archive, second: $0) }
        let unreadable = directory.appendingPathComponent("\(records[0].id).json")
        let library = NoteLibrary(archive: archive)
        var mutationError: Error?
        var last = NoteLoadProgress.opening
        do {
            try await library.loadHistory(activeRecordingID: nil, pageSize: 2) { progress in
                last = progress
                guard progress == .reading(loaded: 1, total: 2) else { return }
                do {
                    try FileManager.default.removeItem(at: unreadable)
                    if replacement == "directory" {
                        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
                    } else {
                        try FileManager.default.createSymbolicLink(at: unreadable, withDestinationURL: directory.appendingPathComponent("missing-target"))
                    }
                } catch { mutationError = error }
            }
            Issue.record("An unreadable entry still present in the folder must fail the page")
        } catch let failure as NoteLoadFailure {
            #expect(failure.operation == .readNote)
            #expect(failure.url.lastPathComponent == unreadable.lastPathComponent)
            #expect(failure.url.deletingLastPathComponent().resolvingSymlinksInPath().path ==
                    unreadable.deletingLastPathComponent().resolvingSymlinksInPath().path)
            let error = failure.underlying as NSError
            if replacement == "dangling-link" {
                #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue)
            } else {
                #expect(error.domain != NSCocoaErrorDomain || error.code != CocoaError.fileReadNoSuchFile.rawValue)
            }
        }
        #expect(mutationError == nil)
        #expect(last == .reading(loaded: 1, total: 2))
        #expect(library.notes.map(\.id) == [records[1].id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(unreadable.lastPathComponent))
    }
}
