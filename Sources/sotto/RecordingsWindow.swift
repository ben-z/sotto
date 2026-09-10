import AppKit
import AVFoundation
import SwiftUI
import SottoCore

@MainActor
final class RecordingsWindow: NSWindowController, NSWindowDelegate {
    let library: NoteLibrary
    private let model: RecordingsModel
    private let onClose: () -> Void
    private var refreshVersion = 0
    var busy: Bool { model.working || model.editing }

    init(session: Session, onClose: @escaping () -> Void) throws {
        library = NoteLibrary(archive: session.archive)
        model = RecordingsModel(library: library, session: session)
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Sotto Recordings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 460)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: RecordingsView(model: model, library: library, session: session))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate() }
    func refresh() {
        refreshVersion += 1
        if [.preparing, .recording].contains(model.session.state) { model.stop() }
        guard !model.loading, !model.working else { return }
        model.loading = true
        Task {
            do {
                var loadedVersion: Int
                repeat {
                    loadedVersion = refreshVersion
                    try await library.reloadAsync()
                } while loadedVersion != refreshVersion
                var activeIDs = Set<String>()
                if let id = model.session.activeRecordingID { activeIDs.insert(id) }
                try library.recoverInterrupted(excluding: activeIDs)
            } catch { model.error = error.localizedDescription }
            model.loading = false
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if busy { model.error = "Finish transcription or save or cancel your edits before closing this window."; return false }
        return true
    }
    func windowWillClose(_ notification: Notification) { model.stop(); onClose() }
}

@MainActor
final class RecordingsModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    let library: NoteLibrary
    let session: Session
    @Published var selection = Set<String>()
    @Published var error: String?
    @Published var playingID: String?
    @Published var loading = false
    @Published var working = false
    @Published var editing = false
    private var player: AVAudioPlayer?
    private var worker: Task<Void, Never>?
    init(library: NoteLibrary, session: Session) { self.library = library; self.session = session }
    var busy: Bool { loading || working || editing || [.preparing, .recording, .transcribing].contains(session.state) }
    func perform(_ action: () throws -> Void) {
        do { try action(); error = nil }
        catch { self.error = error.localizedDescription; AppLog.shared.record(error.localizedDescription, error: true) }
    }
    func stop() { player?.stop(); player = nil; playingID = nil }
    func play(_ note: RecordingRecord) {
        if playingID == note.id { stop(); return }
        perform {
            stop()
            let value = try AVAudioPlayer(contentsOf: library.archive.audioURL(note))
            value.delegate = self
            guard value.play() else { throw SottoError("This recording could not be played.") }
            player = value; playingID = note.id
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stop()
            if !flag { self.error = "Playback stopped unexpectedly. The original audio is retained." }
        }
    }
    func transcribe() {
        guard !busy, !selection.isEmpty else { return }
        stop()
        perform {
            try library.transcribe(selection, model: session.configuration.model, language: session.configuration.language)
        }
        guard error == nil else { return }
        working = true
        let ids = selection
        worker = Task {
            await library.process(ids: ids, key: { try GroqKeychain.read() }) { [session] url, key, note in
                try await GroqClient().transcribe(file: url, key: key, model: note.model, language: note.language,
                                                prompt: note.prompt, trimWhitespace: session.configuration.trimWhitespace)
            }
            error = library.issue
            if let error { AppLog.shared.record(error, error: true) }
            working = false
            worker = nil
        }
    }
    func cancelTranscription() { worker?.cancel() }
}

private struct RecordingsView: View {
    @ObservedObject var model: RecordingsModel
    @ObservedObject var library: NoteLibrary
    @ObservedObject var session: Session
    @State private var deleting = false
    var body: some View {
        NavigationSplitView {
            List(library.notes, selection: $model.selection) { note in
                RecordingSummary(note: note).tag(note.id)
            }
            .disabled(model.editing)
            .overlay {
                if model.loading { ProgressView("Loading recordings…") }
                else if library.notes.isEmpty { ContentUnavailableView("No recordings", systemImage: "waveform", description: Text("Your recordings will appear here.")) }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        } detail: {
            if model.selection.count == 1, let note = library.notes.first(where: { model.selection.contains($0.id) }) {
                RecordingDetail(model: model, library: library, note: note).id(note.id)
            } else {
                ContentUnavailableView(model.selection.isEmpty ? "Select a recording" : "\(model.selection.count) recordings selected",
                                       systemImage: "waveform", description: Text("Listen, edit, or transcribe your saved audio."))
            }
        }
        .toolbar {
            Button("Show Recordings Folder", systemImage: "folder") { NSWorkspace.shared.open(library.archive.directory) }
            Spacer()
            if model.working { Button("Cancel Transcription") { model.cancelTranscription() } }
            Button("Transcribe…") { confirming = true }.disabled(model.selection.isEmpty || model.busy)
            Button("Delete…") { deleting = true }.disabled(model.selection.isEmpty || model.busy)
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { model.error = nil }.labelStyle(.iconOnly)
                }.padding().background(.bar)
            }
        }
        .confirmationDialog("Delete \(selectionDescription)?", isPresented: $deleting) {
            Button("Delete Recordings", role: .destructive) {
                model.stop()
                model.perform { try library.delete(model.selection); model.selection.removeAll() }
            }
        } message: { Text("This permanently deletes the selected audio, transcripts, and notes.") }
        .confirmationDialog("Transcribe \(selectionDescription)?", isPresented: $confirming) {
            Button("Transcribe") { model.transcribe() }
        } message: {
            Text("Model: \(session.configuration.model)\nLanguage: \(session.configuration.language ?? "Automatic")\nUses your transcription settings. Existing machine transcripts are replaced; edited notes are retained.")
        }
    }
    private var selectionDescription: String { "\(model.selection.count) " + (model.selection.count == 1 ? "recording" : "recordings") }
    @State private var confirming = false
}

private struct RecordingDetail: View {
    @ObservedObject var model: RecordingsModel
    @ObservedObject var library: NoteLibrary
    let note: RecordingRecord
    @State private var title = ""
    @State private var text = ""
    @State private var renaming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { title = note.title ?? note.generatedTitle ?? ""; renaming = true } label: {
                HStack { Text(note.displayTitle).font(.title2); Image(systemName: "pencil").foregroundStyle(.secondary) }
            }.buttonStyle(.plain).disabled(model.busy)
            .alert("Rename recording", isPresented: $renaming) {
                TextField("Title", text: $title)
                Button("Cancel", role: .cancel) { }
                Button("Save") { model.perform { try library.rename(note, to: title) } }
            }
            Text(note.startedAt, format: .dateTime.year().month().day().hour().minute().timeZone()).foregroundStyle(.secondary)
            HStack {
                Button(model.playingID == note.id ? "Stop Playback" : "Play Recording", systemImage: "play.fill") { model.play(note) }.disabled(model.busy)
                ShareLink("Share Audio", item: library.archive.audioURL(note))
                Spacer()
                Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.archive.audioURL(note)]) }
            }
            if let error = note.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            if let used = note.transcribedModel { Text("Transcribed with \(used)").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("Note").font(.headline)
                Spacer()
                if model.editing {
                    Button("Cancel") { model.editing = false; load() }
                    Button("Save") { model.perform { try library.saveText(text, for: note); model.editing = false } }.keyboardShortcut("s")
                } else {
                    ShareLink("Share Note", item: text).disabled(text.isEmpty)
                    Button("Edit Note") { model.editing = true }.disabled(model.busy)
                }
            }
            if model.editing { TextEditor(text: $text).font(.body) }
            else { ScrollView { Text(text.isEmpty ? "No transcript yet. Select Transcribe to process the retained audio." : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
        }
        .padding(24)
        .onAppear { title = note.title ?? note.generatedTitle ?? ""; load() }
        .onChange(of: note.status) { _, _ in if !model.editing { load() } }
    }
    private func load() { model.perform { text = try library.text(for: note) } }
}
