import SwiftUI
import AVFoundation
import OSLog
import AppIntents
import Network
import UniformTypeIdentifiers
import SottoCore

@main
struct SottoNotesApp: App {
    @StateObject private var store = NotesStore.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            Group {
                if let library = store.library { NotesView(store: store, library: library).id(ObjectIdentifier(library)) }
                else { ContentUnavailableView("Cannot open notes", systemImage: "exclamationmark.triangle", description: Text(store.error ?? "Loading notes")) }
            }
            .onChange(of: phase) { _, value in
                if value == .active { store.resume() }
                if value == .background { store.suspend() }
            }
        }
    }
}

@MainActor
final class NotesStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = NotesStore()
    @Published var library: NoteLibrary?
    @Published var recording: RecordingRecord?
    @Published var preparing = false
    @Published var error: String?
    @Published var playingID: String?
    @Published var keyStored = false
    private let recorder = Recorder()
    private let log = Logger(subsystem: "dev.sotto.notes", category: "audio")
    private var player: AVAudioPlayer?
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private let network = NWPathMonitor()
    private var scopedFolder: URL?
    var model: String { UserDefaults.standard.string(forKey: "notes.model") ?? "whisper-large-v3-turbo" }
    var language: String? {
        let value = UserDefaults.standard.string(forKey: "notes.language") ?? "en"
        return value.isEmpty ? nil : value
    }

    override init() {
        super.init()
        do {
            var directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
            let bookmark = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sotto/folder.bookmark")
            if FileManager.default.fileExists(atPath: bookmark.path) {
                var stale = false
                let folder = try URL(resolvingBookmarkData: Data(contentsOf: bookmark), bookmarkDataIsStale: &stale)
                guard !stale, folder.startAccessingSecurityScopedResource() else { throw SottoError("The saved recording folder is unavailable. Restore its access before opening notes.") }
                scopedFolder = folder; directory = folder
            }
            library = try NoteLibrary(directory: directory)
        } catch { self.error = error.localizedDescription }
        refreshKey()
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        recorder.onUnexpectedStop = { [weak self] message in
            self?.finish()
            if let message { self?.error = message }
        }
        network.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.resume() }
        }
        network.start(queue: DispatchQueue(label: "dev.sotto.notes.network"))
    }

    @objc nonisolated private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor [weak self] in self?.finish() }
    }

    func refreshKey() {
        switch GroqKeychain.storageStatus() {
        case .stored, .authorizationRequired: keyStored = true
        case .missing: keyStored = false
        case .failure(let code): error = "Keychain could not be read (\(code))."
        }
    }

    func toggleRecording() async {
        if recording != nil { finish(); return }
        guard !preparing, let library else { return }
        preparing = true; error = nil; stopPlayback()
        defer { preparing = false }
        log.notice("Requesting microphone permission")
        guard await Recorder.requestPermission() else {
            log.error("Microphone permission denied")
            error = "Allow microphone access in iPhone Settings → Sotto to record a note."; return
        }
        log.notice("Microphone permission granted")
        do {
            let note = try library.create(model: model, language: language)
            log.notice("Starting recorder")
            do { try recorder.start(at: library.archive.audioURL(note), bitRate: 32000) }
            catch {
                var failed = note; failed.status = "interrupted"; failed.error = error.localizedDescription
                try library.save(failed); throw error
            }
            recording = note
            log.notice("Recording \(note.id, privacy: .public)")
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1800)); self?.finish() } catch { }
            }
        } catch { self.error = error.localizedDescription }
    }

    func finish() {
        guard let note = recording, let library else { return }
        deadline?.cancel(); deadline = nil; error = nil
        do {
            let duration = try recorder.stop()
            recording = nil
            try library.queue(note, duration: duration)
            log.notice("Saved audio \(note.id, privacy: .public)")
            resume()
        } catch { recording = nil; self.error = error.localizedDescription }
    }

    func resume() {
        guard worker == nil, let library, keyStored, UIApplication.shared.applicationState == .active else { return }
        worker = Task { [weak self] in
            await library.process(key: { try GroqKeychain.read() }) { url, key, note in
                try await GroqClient().transcribe(file: url, key: key, model: note.model, language: note.language, prompt: note.prompt)
            }
            self?.worker = nil
            if Task.isCancelled { self?.resume() }
        }
    }

    func suspend() {
        // Active recording uses the audio background mode; uploads resume on foreground.
        stopPlayback(); worker?.cancel()
    }

    func selectFolder(_ url: URL) throws {
        guard recording == nil, !preparing, worker == nil else { throw SottoError("Finish recording and transcription before changing folders.") }
        guard url.startAccessingSecurityScopedResource() else { throw SottoError("Cannot access the chosen folder.") }
        do {
            let replacement = try NoteLibrary(directory: url)
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sotto")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try bookmark.write(to: support.appendingPathComponent("folder.bookmark"), options: .atomic)
            scopedFolder?.stopAccessingSecurityScopedResource(); scopedFolder = url
            library = replacement; error = nil
            resume()
        } catch { url.stopAccessingSecurityScopedResource(); throw error }
    }

    func deleteKey() throws {
        try GroqKeychain.delete(); refreshKey(); worker?.cancel()
    }

    func retry(_ note: RecordingRecord) {
        do { try library?.queue(note); resume() } catch { self.error = error.localizedDescription }
    }

    func play(_ note: RecordingRecord) {
        if playingID == note.id { stopPlayback(); return }
        guard recording == nil, let library else { return }
        error = nil
        do {
            stopPlayback()
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let value = try AVAudioPlayer(contentsOf: library.archive.audioURL(note))
            value.delegate = self
            guard value.play() else { throw SottoError("This recording could not be played.") }
            player = value; playingID = note.id
        } catch { self.error = error.localizedDescription }
    }

    func stopPlayback() {
        guard player != nil else { return }
        player?.stop(); player = nil; playingID = nil
        do { try AVAudioSession.sharedInstance().setActive(false) } catch { self.error = error.localizedDescription }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopPlayback()
            if !flag { self.error = "Playback stopped unexpectedly. The original audio is retained." }
        }
    }
}

struct RecordVoiceNote: AppIntent {
    static let title: LocalizedStringResource = "Record a voice note"
    static let description = IntentDescription("Open Sotto and start recording. Run again to stop and save.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        await NotesStore.shared.toggleRecording()
        if let error = NotesStore.shared.error { throw SottoError(error) }
        return .result()
    }
}

struct SottoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordVoiceNote(), phrases: ["Record a note in \(.applicationName)"], shortTitle: "Record a voice note", systemImageName: "mic")
    }
}

private func title(_ note: RecordingRecord) -> String {
    if let title = note.title, !title.isEmpty { return title }
    return "Voice note"
}

private func status(_ note: RecordingRecord, keyStored: Bool) -> String {
    switch note.status {
    case "recording": "Recording"
    case "queued": keyStored ? "Waiting to transcribe" : "Audio saved · Add a Groq key to transcribe"
    case "transcribing": "Transcribing"
    case "complete": "Transcribed"
    case "interrupted": "Recording interrupted"
    default: "Transcription needs attention"
    }
}

struct NotesView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var library: NoteLibrary
    @State private var settings = false
    var body: some View {
        NavigationStack {
            List {
                if library.notes.isEmpty {
                    ContentUnavailableView("Your voice notes", systemImage: "waveform", description: Text("Record audio, then turn it into text with Groq. Original recordings are saved locally."))
                        .listRowBackground(Color.clear)
                }
                ForEach(library.notes) { note in
                    NavigationLink {
                        NoteView(store: store, library: library, id: note.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(title(note)).font(.headline)
                            Text(note.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.subheadline).foregroundStyle(.secondary)
                            Label(status(note, keyStored: store.keyStored), systemImage: note.status == "complete" ? "text.alignleft" : "waveform")
                                .font(.caption).foregroundStyle(note.status == "recording" ? .red : .secondary)
                        }.padding(.vertical, 5)
                    }
                }
                if let error = store.error ?? library.issue {
                    Section { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .navigationTitle("Notes")
            .toolbar { Button("Settings", systemImage: "gearshape") { settings = true } }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if store.preparing { ProgressView("Preparing microphone") }
                    if let note = store.recording {
                        Text(note.startedAt, style: .timer).monospacedDigit().font(.title2)
                        Text("Recording · Original audio is retained").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { Task { await store.toggleRecording() } } label: {
                        Label(store.recording == nil ? "Record a note" : "Stop recording", systemImage: store.recording == nil ? "mic.fill" : "stop.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).tint(store.recording == nil ? .accentColor : .red)
                        .disabled(store.preparing).accessibilityIdentifier("record-note")
                }.padding().background(.bar)
            }
            .sheet(isPresented: $settings) { SettingsView(store: store) }
        }
    }
}

struct NoteView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var library: NoteLibrary
    let id: String
    @State private var editing = false
    @State private var draft = ""
    @State private var draftTitle = ""
    @State private var error: String?
    private var note: RecordingRecord? { library.notes.first { $0.id == id } }
    var body: some View {
        if let note {
            List {
                Section {
                    Text(note.startedAt, format: .dateTime.month(.wide).day().year().hour().minute()).foregroundStyle(.secondary)
                    HStack {
                        Button(store.playingID == id ? "Stop playback" : "Play recording", systemImage: store.playingID == id ? "stop.fill" : "play.fill") { store.play(note) }
                            .disabled(store.recording != nil)
                        Spacer()
                        if let seconds = note.durationSeconds { Text(Duration.seconds(seconds), format: .time(pattern: .minuteSecond)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    ShareLink("Share audio", item: library.archive.audioURL(note))
                }
                Section("Note") {
                    switch Result(catching: { try library.text(for: note) }) {
                    case .success(let text):
                        if text.isEmpty { Text(status(note, keyStored: store.keyStored)).foregroundStyle(.secondary) }
                        else { Text(text).textSelection(.enabled); ShareLink("Share note", item: text) }
                    case .failure(let error):
                        Text("Cannot read note: \(error.localizedDescription)").foregroundStyle(.red)
                    }
                    if let message = note.error { Text(message).font(.caption).foregroundStyle(.red) }
                    if ["failed", "interrupted", "queued"].contains(note.status) {
                        Button("Transcribe recording") { store.retry(note) }.disabled(!store.keyStored || library.transcribingID == id)
                    }
                }
                if let error = error ?? store.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(title(note)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Edit") {
                    do { draft = try library.text(for: note); draftTitle = note.title ?? ""; editing = true }
                    catch { self.error = error.localizedDescription }
                }
            }
            .onDisappear { store.stopPlayback() }
            .sheet(isPresented: $editing) {
                NavigationStack {
                    Form {
                        TextField("Title", text: $draftTitle)
                        TextEditor(text: $draft).frame(minHeight: 250).accessibilityLabel("Note text")
                        if let error { Text(error).foregroundStyle(.red) }
                    }.navigationTitle("Edit note").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = false } }
                            ToolbarItem(placement: .confirmationAction) { Button("Save") {
                                do { try library.saveText(draft, for: note); try library.rename(note, to: draftTitle); editing = false }
                                catch { self.error = error.localizedDescription }
                            } }
                        }
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notes.model") private var model = "whisper-large-v3-turbo"
    @AppStorage("notes.language") private var language = "en"
    @State private var key = ""
    @State private var folderPicker = false
    @State private var folderError: String?
    @State private var checking = false
    @State private var keyResult: Result<String, Error>?
    var body: some View {
        NavigationStack {
            Form {
                Section("Transcription") {
                    Text(store.keyStored ? "API key saved in this iPhone’s Keychain" : "Add a Groq API key to transcribe your recordings.")
                    SecureField(store.keyStored ? "Replace API key" : "Groq API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(checking)
                    Button(checking ? "Checking key…" : "Save and check key") {
                        Task {
                            let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
                            checking = true; keyResult = nil
                            defer { checking = false }
                            do {
                                try await GroqClient().verifyKey(candidate, model: model)
                                try GroqKeychain.save(candidate); key = ""; store.refreshKey(); store.resume()
                                keyResult = .success("Key verified and saved. Queued recordings will transcribe automatically.")
                            } catch { keyResult = .failure(error) }
                        }
                    }.disabled(checking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Link("Create a Groq API key", destination: URL(string: "https://console.groq.com/keys")!)
                    if store.keyStored {
                        Button("Delete API key", role: .destructive) {
                            do { try store.deleteKey(); keyResult = .success("API key deleted. Your recordings are retained.") }
                            catch { keyResult = .failure(error) }
                        }.disabled(checking)
                    }
                    if let keyResult {
                        switch keyResult {
                        case .success(let message): Text(message).font(.callout).foregroundStyle(.secondary)
                        case .failure(let error): Text(error.localizedDescription).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    Picker("Language", selection: $language) { Text("English").tag("en"); Text("Detect automatically").tag("") }
                    Picker("Model", selection: $model) {
                        Text("whisper-large-v3-turbo").tag("whisper-large-v3-turbo")
                        Text("whisper-large-v3").tag("whisper-large-v3")
                    }
                } footer: { Text("Applies to new recordings. Audio is sent to Groq for transcription using your key.") }
                Section("Storage") {
                    if let directory = store.library?.archive.directory {
                        Text("Library: \(directory.lastPathComponent)")
                        DisclosureGroup("Folder location") { Text(directory.path).font(.caption).textSelection(.enabled) }
                    }
                    Button("Choose library folder") { folderError = nil; folderPicker = true }
                        .disabled(store.recording != nil || store.preparing)
                    Text("The default folder is Files → On My iPhone → Sotto → Recordings. Choosing a folder opens its notes; existing notes stay in their current folder.").font(.caption).foregroundStyle(.secondary)
                    if let folderError { Text(folderError).font(.caption).foregroundStyle(.red) }
                    Text("Audio, the original transcript, and your edits are kept together. Back up this folder before deleting the app.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Action Button") {
                    Text("In iPhone Settings → Action Button, choose Shortcut, then Sotto → Record a voice note.")
                    Text("The shortcut opens Sotto to record. Run it again or tap Stop to save. Recording continues when you lock your iPhone. Tap Stop in Sotto to finish.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder]) { result in
                    do { try store.selectFolder(result.get()); dismiss() }
                    catch { folderError = error.localizedDescription }
                }
        }
    }
}
