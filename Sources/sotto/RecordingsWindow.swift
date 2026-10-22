import AppKit
import AVFoundation
import SwiftUI
import SottoCore
import SottoUI

@MainActor
final class RecordingsWindow: NSWindowController, NSWindowDelegate {
    let library: NoteLibrary
    private let model: RecordingsModel
    private let onClose: () -> Void
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
    func refresh() { model.refresh() }
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
    enum HistoryRequest { case refresh, older }
    @Published var loading = false
    @Published private(set) var historyProgress: NoteLoadProgress?
    @Published private(set) var historyFailure: (request: HistoryRequest, message: String)?
    @Published var working = false {
        didSet { if !working && needsRefresh { refresh() } }
    }
    @Published var editing = false {
        didSet { if !editing && needsRefresh { refresh() } }
    }
    private var player: AVAudioPlayer?
    private var worker: Task<Void, Never>?
    private var needsRefresh = false
    init(library: NoteLibrary, session: Session) { self.library = library; self.session = session }
    var busy: Bool { loading || working || editing || [.preparing, .recording, .transcribing].contains(session.state) }
    func refresh() {
        needsRefresh = true
        if [.preparing, .recording].contains(session.state) { stop() }
        guard !loading, !working, !editing else { return }
        startHistory(.refresh)
    }
    func loadMore() {
        guard !loading, !working, !editing, library.hasMoreHistory else { return }
        startHistory(.older)
    }
    func retryHistory() {
        guard let historyFailure else { return }
        switch historyFailure.request {
        case .refresh: refresh()
        case .older: loadMore()
        }
    }
    private func startHistory(_ request: HistoryRequest) {
        loading = true
        Task {
            defer { loading = false; historyProgress = nil }
            var current = request
            repeat {
                if current == .refresh { needsRefresh = false }
                historyFailure = nil
                do {
                    let report: @MainActor @Sendable (NoteLoadProgress) -> Void = { self.historyProgress = $0 }
                    switch current {
                    case .refresh:
                        defer { library.invalidateText() }
                        // Session persists its recording directly to Archive; refresh reads that current state.
                        try await library.loadHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize, progress: report)
                    case .older:
                        try await library.loadMoreHistory(activeRecordingID: nil, pageSize: Configuration.historyPageSize, progress: report)
                    }
                    selection.formIntersection(Set(library.notes.map(\.id)))
                } catch {
                    historyFailure = (current, error.localizedDescription)
                }
                current = .refresh
            } while needsRefresh && !working && !editing
        }
    }
    var selectionIncludesUnfinishedNotes: Bool {
        library.notes.contains { selection.contains($0.id) && $0.hasUnfinishedOperation }
    }
    func perform(_ action: () throws -> Void) {
        do { try action(); error = nil }
        catch { self.error = error.localizedDescription; AppLog.shared.record(error.localizedDescription, error: true) }
    }
    func stop() { player?.delegate = nil; player?.stop(); player = nil; playingID = nil }
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
        // Retain the non-Sendable source across dispatch; the handler only compares its identity.
        nonisolated(unsafe) let source = player
        Task { @MainActor in
            guard self.player === source else { return }
            self.stop()
            if !flag { self.error = "Playback stopped unexpectedly. The original audio is retained." }
        }
    }
    func transcribe(model: String, language: String?) throws {
        guard !busy, !selection.isEmpty else { throw SottoError("Select recordings after the current operation finishes.") }
        stop()
        try library.transcribe(selection, model: model, language: language)
        error = nil
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
    @State private var refreshOnActivation = false
    var body: some View {
        NavigationSplitView {
            GeometryReader { geometry in
                List(selection: $model.selection) {
                    ForEach(library.notes) { note in
                        RecordingSummary(note: note, isActive: note.id == session.activeRecordingID || note.id == library.transcribingID).tag(note.id)
                    }
                    if case let .reading(loaded, total) = model.historyProgress {
                        ProgressView(value: Double(loaded), total: Double(max(total, 1))) {
                            Text("Loaded \(loaded) of \(total) notes")
                        }
                    }
                    HistoryPagingFooter(viewport: geometry.frame(in: .global), loading: model.loading,
                                        canLoadMore: library.hasMoreHistory && model.historyFailure == nil && !model.working && !model.editing) { model.loadMore() }
                }
                .disabled(model.editing)
                .overlay {
                    if !model.loading && library.notes.isEmpty && model.historyFailure == nil {
                        ContentUnavailableView("No recordings", systemImage: "waveform", description: Text("Your recordings will appear here."))
                    }
                }
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
        .navigationTitle("Sotto Recordings")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            refreshOnActivation = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if refreshOnActivation {
                refreshOnActivation = false
                model.refresh()
            }
        }
        .toolbar {
            Button("Show Recordings Folder", systemImage: "folder") { NSWorkspace.shared.open(library.archive.directory) }
            Button("Refresh Recordings", systemImage: "arrow.clockwise") { model.refresh() }
                .disabled(model.loading || model.working || model.editing)
            Spacer()
            if model.working { Button("Cancel Transcription") { model.cancelTranscription() } }
            Button(transcriptionTitle) { confirming = true }.disabled(model.selection.isEmpty || model.busy || model.selectionIncludesUnfinishedNotes)
            Button("Delete…") { deleting = true }.disabled(model.selection.isEmpty || model.busy || model.selectionIncludesUnfinishedNotes)
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.error ?? model.historyFailure?.message {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    if model.error != nil {
                        Button("Dismiss", systemImage: "xmark") { model.error = nil }.labelStyle(.iconOnly)
                    } else {
                        Button("Try again") { model.retryHistory() }
                    }
                }.padding().background(.bar)
            }
        }
        .confirmationDialog("Delete \(selectionDescription)?", isPresented: $deleting) {
            Button("Delete Recordings", role: .destructive) {
                model.stop()
                model.perform { try library.delete(model.selection); model.selection.removeAll() }
            }
        } message: { Text("This permanently deletes the selected audio, transcripts, and notes.") }
        .sheet(isPresented: $confirming) {
            TranscriptionSheet(count: model.selection.count, model: session.configuration.model,
                               language: session.configuration.language, keyStored: GroqKeychain.storageStatus() != .missing) { selectedModel, language in
                try model.transcribe(model: selectedModel, language: language)
            }
        }
    }
    private var transcriptionTitle: String {
        guard model.selection.count == 1, let note = library.notes.first(where: { model.selection.contains($0.id) }) else { return "Transcribe…" }
        return note.transcriptionActionTitle
    }
    private var selectionDescription: String { "\(model.selection.count) " + (model.selection.count == 1 ? "recording" : "recordings") }
    @State private var confirming = false
}

private struct RecordingDetail: View {
    @ObservedObject var model: RecordingsModel
    @ObservedObject var library: NoteLibrary
    let note: RecordingRecord
    @State private var title = ""
    @State private var renaming = false
    private var isActive: Bool { note.id == model.session.activeRecordingID || note.id == library.transcribingID }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { title = note.title ?? note.generatedTitle ?? ""; renaming = true } label: {
                HStack { Text(note.displayTitle).font(.title2); Image(systemName: "pencil").foregroundStyle(.secondary) }
            }.buttonStyle(.plain).disabled(model.busy || (note.hasUnfinishedOperation && !isActive))
            .alert("Rename recording", isPresented: $renaming) {
                TextField("Title", text: $title)
                Button("Cancel", role: .cancel) { }
                Button("Save") { model.perform { try library.rename(note, to: title, activeRecordingID: model.session.activeRecordingID) } }
            }
            Text(note.startedAt, format: .dateTime.year().month().day().hour().minute().timeZone()).foregroundStyle(.secondary)
            if note.hasUnfinishedOperation && !isActive {
                RecoverNoteButton {
                    model.perform { try library.recover(note.id, activeRecordingID: model.session.activeRecordingID) }
                }.disabled(model.busy)
            }
            HStack {
                Button(model.playingID == note.id ? "Stop Playback" : "Play Recording", systemImage: "play.fill") { model.play(note) }.disabled(model.busy)
                ShareLink("Share Audio", item: library.archive.audioURL(note))
                Spacer()
                Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.archive.audioURL(note)]) }
            }
            ScrollView {
                NoteContent(library: library, id: note.id, canEdit: !model.busy && !note.hasUnfinishedOperation) { model.editing = $0 }
                    .id(note.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
    }
}
