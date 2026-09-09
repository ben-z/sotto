import SwiftUI
import UniformTypeIdentifiers
import SottoCore

@main
struct SottoNotesApp: App {
    @StateObject private var store = NotesStore()
    var body: some Scene {
        WindowGroup {
            Group {
                if let session = store.session { NotesView(session: session, store: store).id(ObjectIdentifier(session)) }
                else {
                    VStack {
                        ContentUnavailableView("Sotto could not start", systemImage: "exclamationmark.triangle", description: Text(store.error ?? "Loading"))
                        if store.error != nil { Button("Reset configuration · keep recordings") { store.resetConfiguration() } }
                    }
                }
            }.task { store.load() }
        }
    }
}

@MainActor
final class NotesStore: ObservableObject {
    @Published var session: Session?
    @Published var error: String?
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sotto")
    private var scopedFolder: URL?

    func resetConfiguration() {
        do {
            let config = Configuration(recordingsDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings").path)
            try config.save(to: support.appendingPathComponent("config.json"))
            let bookmark = support.appendingPathComponent("folder.bookmark")
            if FileManager.default.fileExists(atPath: bookmark.path) { try FileManager.default.removeItem(at: bookmark) }
            scopedFolder?.stopAccessingSecurityScopedResource(); scopedFolder = nil
            error = nil; session = nil; load()
        } catch { self.error = error.localizedDescription }
    }

    func load() {
        guard session == nil else { return }
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let configURL = support.appendingPathComponent("config.json")
            var config: Configuration
            if FileManager.default.fileExists(atPath: configURL.path) { config = try Configuration.load(from: configURL) }
            else {
                config = Configuration(recordingsDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings").path)
                try config.save(to: configURL)
            }
            let bookmarkURL = support.appendingPathComponent("folder.bookmark")
            if FileManager.default.fileExists(atPath: bookmarkURL.path) {
                var stale = false
                let folder = try URL(resolvingBookmarkData: Data(contentsOf: bookmarkURL), options: [], bookmarkDataIsStale: &stale)
                guard !stale, folder.startAccessingSecurityScopedResource() else { throw SottoError("Recording folder permission expired. Re-select the folder using Settings after restoring access.") }
                scopedFolder = folder
                config.recordingsDirectory = folder.path
            } else {
                // iOS may relocate its app container across installs/updates.
                config.recordingsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings").path
            }
            session = try Session(configuration: config)
        } catch { self.error = error.localizedDescription }
    }

    func selectFolder(_ url: URL) throws {
        guard let old = session, [.idle, .error].contains(old.state) else { throw SottoError("Finish the current recording first.") }
        guard url.startAccessingSecurityScopedResource() else { throw SottoError("Cannot access the chosen folder.") }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            var config = old.configuration; config.recordingsDirectory = url.path
            let replacement = try Session(configuration: config)
            try bookmark.write(to: support.appendingPathComponent("folder.bookmark"), options: .atomic)
            scopedFolder?.stopAccessingSecurityScopedResource(); scopedFolder = url
            session = replacement
        } catch { url.stopAccessingSecurityScopedResource(); throw error }
    }
}

struct NotesView: View {
    @ObservedObject var session: Session
    @ObservedObject var store: NotesStore
    @State private var key = ""
    @State private var settings = false
    @State private var folderPicker = false
    @State private var files: [URL] = []
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(session.message).font(.caption).textSelection(.enabled)
                    Button(session.state == .recording ? "Stop and transcribe" : "Record note", systemImage: session.state == .recording ? "stop.circle.fill" : "mic.circle.fill") {
                        Task {
                            if session.state == .recording { await session.finish() }
                            else { await session.begin() }
                        }
                    }.disabled(session.state == .transcribing || session.state == .preparing)
                    if session.state == .recording || session.state == .transcribing {
                        Button("Cancel · keep audio", role: .cancel) { Task { await session.cancel() } }
                    }
                }
                Section("Recent notes") {
                    ForEach(files, id: \.self) { url in
                        NavigationLink(url.deletingPathExtension().lastPathComponent) { NoteView(url: url) }
                    }
                    if files.isEmpty { Text("Record a note to get started.").foregroundStyle(.secondary) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Sotto")
            .toolbar { Button("Settings", systemImage: "gear") { settings = true } }
            .task { refresh() }
            .onChange(of: session.lastTranscript) { refresh() }
            .onChange(of: scenePhase) { _, phase in
                // First version is foreground-only. Finalize the file when
                // leaving, instead of risking a suspended unfinished recording.
                if phase == .background { Task { await session.cancel() } }
            }
            .sheet(isPresented: $settings) {
                NavigationStack {
                    Form {
                        Section("Groq") {
                            SecureField("API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Save key to Keychain") {
                                do { try GroqKeychain.save(key); key = ""; error = nil; settings = false }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        Section("Keep all audio") {
                            Text(session.archive.directory.path).font(.caption).textSelection(.enabled)
                            Button("Choose recording folder") { folderPicker = true }
                                .disabled(![.idle, .error].contains(session.state))
                            Text("AAC audio, transcript, and diagnostics stay together. The default folder is available in Files → On My iPhone → Sotto.").font(.caption)
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                    }.navigationTitle("Settings")
                        .toolbar { Button("Done") { settings = false } }
                }
            }
            .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder]) { result in
                do { try store.selectFolder(result.get()); settings = false; refresh() }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func refresh() {
        do {
            files = try FileManager.default.contentsOfDirectory(at: session.archive.directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(50).map { $0 }
        } catch { self.error = error.localizedDescription }
    }
}

struct NoteView: View {
    let url: URL
    @State private var text = ""
    var body: some View {
        ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            .navigationTitle("Note")
            .toolbar { ShareLink(item: url) }
            .task {
                do { text = try String(contentsOf: url, encoding: .utf8) }
                catch { text = "Cannot read note: \(error.localizedDescription)" }
            }
    }
}
