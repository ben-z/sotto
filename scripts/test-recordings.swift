import AppKit
import Combine
import SottoCore

@main struct RecordingsTests {
    @MainActor static func main() async throws {
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SottoError(message) }
        }
        func finish(_ model: RecordingsModel) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while model.loading && ContinuousClock.now < deadline { await Task.yield() }
            try expect(!model.loading, "Recordings refresh did not finish within ten seconds")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: directory) }
        let session = try Session(configuration: Configuration(recordingsDirectory: directory.path))
        let archive = session.archive
        var original = try archive.newRecord(model: "fixture", language: "en", prompt: "", contextTerms: [])
        original.status = "complete"; original.title = "Original recording"
        try archive.save(original)
        original.status = "recording"; try archive.save(original)
        let library = NoteLibrary(archive: archive)
        let model = RecordingsModel(library: library, session: session)
        model.refresh(); try await finish(model)
        try expect(library.notes.first?.status == "recording", "A new window omitted an unfinished recording")
        original.status = "transcribing"; try archive.save(original)
        model.refresh(); try await finish(model)
        try expect(library.notes.first?.status == "transcribing", "Refresh did not show a recording's current transcription status")
        original.status = "complete"; try archive.save(original)
        model.refresh(); try await finish(model)
        model.selection = [original.id]

        model.editing = true
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(original.id).json"))
        var replacement = try archive.newRecord(model: "fixture", language: "en", prompt: "", contextTerms: [])
        replacement.status = "complete"; replacement.title = "Replacement recording"
        try archive.save(replacement)
        model.refresh()
        try expect(!model.loading && library.notes.map(\.id) == [original.id], "Refresh replaced the note backing an open editor")
        try expect(model.selection == [original.id], "Refresh cleared the selection while editing")
        model.editing = false
        try expect(model.loading, "Closing the editor did not resume its pending refresh")
        try await finish(model)
        try expect(library.notes.map(\.id) == [replacement.id] && model.selection.isEmpty, "Refresh did not reconcile external deletion and selection")

        model.selection = [replacement.id]
        model.working = true
        replacement.title = "Changed during transcription"
        try archive.save(replacement)
        model.refresh()
        try expect(!model.loading && library.notes[0].title == "Replacement recording", "Refresh ran during a local transcription")
        model.working = false
        try await finish(model)
        try expect(library.notes[0].title == replacement.title && model.selection == [replacement.id], "Finishing transcription lost the pending refresh or selection")

        var requested = false
        var mutationError: Error?
        var latest = replacement
        latest.title = "Changed after the snapshot was read"
        let observation = library.$notes.dropFirst().sink { _ in
            MainActor.assumeIsolated {
                guard !requested else { return }
                requested = true
                do { try archive.save(latest); model.refresh() }
                catch { mutationError = error }
            }
        }
        model.refresh()
        try await finish(model)
        observation.cancel()
        if let mutationError { throw mutationError }
        try expect(requested && library.notes[0].title == latest.title, "A refresh requested during loading was lost")

        let metadata = directory.appendingPathComponent("\(latest.id).json")
        try Data("{".utf8).write(to: metadata)
        model.refresh()
        try await finish(model)
        try expect(model.historyFailure != nil && library.notes[0].title == latest.title, "A failed refresh hid its error or replaced the current notes")
        try expect(model.selection == [latest.id], "A failed refresh discarded the current selection")
        model.editing = true; model.editing = false
        try expect(!model.loading, "A failed refresh retried without a new request")
        try archive.save(latest)
        model.refresh()
        try await finish(model)
        try expect(library.notes[0].title == latest.title, "Explicit refresh could not recover after a metadata error")
        // A cold window opens one page; refreshing keeps the older selected row.
        for index in 0..<120 {
            var note = replacement
            note.startedAt = Date(timeIntervalSince1970: 1_600_000_000 + Double(index * 60))
            note.id = ISO8601DateFormatter().string(from: note.startedAt).replacingOccurrences(of: ":", with: "-") + "-fixture"
            note.audioFile = "\(note.id).m4a"
            note.title = "Paged recording \(index)"
            try archive.save(note)
        }
        let paged = NoteLibrary(archive: archive)
        let pagedModel = RecordingsModel(library: paged, session: session)
        pagedModel.refresh()
        try await finish(pagedModel)
        try expect(paged.notes.count == Configuration.historyPageSize && paged.hasMoreHistory, "Cold window read beyond the first history page")
        pagedModel.loadMore()
        try await finish(pagedModel)
        try expect(paged.notes.count == 2 * Configuration.historyPageSize, "Scrolling did not append the next history page")
        guard let olderSelection = paged.notes.last else { throw SottoError("Missing older row") }
        pagedModel.selection = [olderSelection.id]
        var arrival = try archive.newRecord(model: "fixture", language: "en", prompt: "", contextTerms: [])
        arrival.status = "complete"; arrival.title = "Arrived on another device"
        try archive.save(arrival)
        pagedModel.refresh()
        try await finish(pagedModel)
        try expect(pagedModel.selection == [olderSelection.id] && paged.notes.contains(where: { $0.id == arrival.id }), "Refresh lost the older selected row or a new arrival")
        try expect(paged.notes.count == 2 * Configuration.historyPageSize + 1, "Refresh opened unbrowsed older notes")
        let oldest = directory.appendingPathComponent("2020-09-13T12-26-40Z-fixture.json")
        let validMetadata = try Data(contentsOf: oldest)
        try Data("{".utf8).write(to: oldest)
        pagedModel.loadMore()
        try await finish(pagedModel)
        try expect(pagedModel.historyFailure?.request == .older && paged.hasMoreHistory, "A failed older page lost its retry action")
        try expect(pagedModel.selection == [olderSelection.id], "A failed older page discarded the selection")
        pagedModel.perform { throw SottoError("Playback fixture failed") }
        try expect(pagedModel.error == "Playback fixture failed" && pagedModel.historyFailure?.request == .older, "A new action error discarded the failed history page")
        pagedModel.error = nil
        try validMetadata.write(to: oldest)
        pagedModel.retryHistory()
        try await finish(pagedModel)
        try expect(paged.notes.count == 122 && !paged.hasMoreHistory && pagedModel.historyFailure == nil, "Retry did not finish the failed older page")
        print("Recordings paging, refresh, editor protection, and selection checks passed.")

    }
}
