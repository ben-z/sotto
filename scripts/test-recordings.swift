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
        let library = try NoteLibrary(directory: directory)
        let model = RecordingsModel(library: library, session: session)
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
        try expect(model.error != nil && library.notes[0].title == latest.title, "A failed refresh hid its error or replaced the current notes")
        try expect(model.selection == [latest.id], "A failed refresh discarded the current selection")
        model.editing = true; model.editing = false
        try expect(!model.loading, "A failed refresh retried without a new request")
        try archive.save(latest)
        model.refresh()
        try await finish(model)
        try expect(library.notes[0].title == latest.title, "Explicit refresh could not recover after a metadata error")
        print("Recordings refresh, editor protection, and selection checks passed.")
    }
}
