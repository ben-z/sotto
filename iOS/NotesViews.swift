import SwiftUI
import UniformTypeIdentifiers
import SottoCore

private func timestamp(_ note: RecordingRecord) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = note.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy jmm zzz")
    return formatter.string(from: note.startedAt)
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

private struct TranscriptionSelection: Identifiable {
    let ids: Set<String>
    var id: String { ids.sorted().joined(separator: ",") }
}

struct NotesView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var library: NoteLibrary
    @State private var settings = false
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<String>()
    @State private var deleting = Set<String>()
    @State private var confirmDelete = false
    @State private var transcription: TranscriptionSelection?
    @State private var renaming: RecordingRecord?
    @State private var renameShown = false
    @State private var draftTitle = ""
    private var selectionBusy: Bool {
        library.notes.contains { selection.contains($0.id) && ["recording", "transcribing"].contains($0.status) }
    }
    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if library.notes.isEmpty {
                    ContentUnavailableView("Your voice notes", systemImage: "waveform", description: Text("Record audio, then turn it into text with Groq. Original recordings are saved locally."))
                        .listRowBackground(Color.clear)
                }
                ForEach(library.notes) { note in
                    NavigationLink {
                        NoteView(store: store, library: library, id: note.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(note.displayTitle).font(.headline).lineLimit(2)
                            Text(timestamp(note)).font(.subheadline).foregroundStyle(.secondary)
                            Label(status(note, keyStored: store.keyStored), systemImage: note.status == "complete" ? "text.alignleft" : "waveform")
                                .font(.caption).foregroundStyle(note.status == "recording" ? .red : .secondary)
                        }.padding(.vertical, 5)
                    }
                    .accessibilityIdentifier("note-\(note.id)")
                    .tag(note.id)
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                            renaming = note; draftTitle = note.title ?? note.generatedTitle ?? ""; renameShown = true
                        }
                        Button("Transcribe…", systemImage: "waveform") {
                            transcription = TranscriptionSelection(ids: [note.id])
                        }.disabled(["recording", "transcribing"].contains(note.status))
                        Button("Delete", systemImage: "trash", role: .destructive) { requestDelete([note.id]) }
                            .disabled(["recording", "transcribing"].contains(note.status))
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { requestDelete([note.id]) }
                            .disabled(["recording", "transcribing"].contains(note.status))
                    }
                }
                if let error = store.error ?? library.issue {
                    Section { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? "Done" : "Select") {
                        editMode = editMode.isEditing ? .inactive : .active; selection.removeAll()
                    }.disabled(!editMode.isEditing && (library.notes.isEmpty || store.recording != nil || store.preparing))
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") { settings = true } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if editMode.isEditing {
                        Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Transcribe…", systemImage: "waveform") { transcription = TranscriptionSelection(ids: selection) }
                            Spacer()
                            Button("Delete", systemImage: "trash", role: .destructive) { requestDelete(selection) }
                        }.disabled(selection.isEmpty || selectionBusy)
                        if selectionBusy { Text("Wait for active recordings and transcriptions to finish.").font(.caption) }
                    } else {
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
                    }
                }.padding().background(.bar)
            }
            .onChange(of: store.recording?.id) { _, id in
                if id != nil { editMode = .inactive; selection.removeAll() }
            }
            .sheet(isPresented: $settings) { SettingsView(store: store) }
            .sheet(item: $transcription) { TranscribeSheet(store: store, ids: $0.ids) }
            .alert("Rename note", isPresented: $renameShown) {
                TextField("Title", text: $draftTitle)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let renaming {
                        do { try library.rename(renaming, to: draftTitle) } catch { store.error = error.localizedDescription }
                    }
                }
            }
            .confirmationDialog(deleting.count == 1 ? "Delete this note?" : "Delete \(deleting.count) notes?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete permanently", role: .destructive) {
                    do { try store.delete(deleting); selection.subtract(deleting) }
                    catch { store.error = error.localizedDescription }
                }
            } message: { Text("The recordings, transcripts, and edited notes will be permanently deleted.") }
        }
    }
    private func requestDelete(_ ids: Set<String>) { deleting = ids; confirmDelete = true }
}

struct NoteView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var library: NoteLibrary
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var editing = false
    @State private var renaming = false
    @State private var transcribing = false
    @State private var deleting = false
    @State private var draft = ""
    @State private var draftTitle = ""
    @State private var error: String?
    private var note: RecordingRecord? { library.notes.first { $0.id == id } }
    var body: some View {
        if let note {
            List {
                Section {
                    Button { draftTitle = note.title ?? note.generatedTitle ?? ""; renaming = true } label: {
                        HStack { Text(note.displayTitle).font(.headline).foregroundStyle(.primary); Spacer(); Image(systemName: "pencil") }
                    }.accessibilityLabel("Rename note")
                    Text(timestamp(note)).foregroundStyle(.secondary)
                    if let location = note.location {
                        Link(destination: URL(string: "https://maps.apple.com/?ll=\(location.latitude),\(location.longitude)")!) {
                            Label("Recording location", systemImage: "mappin.and.ellipse")
                        }.accessibilityIdentifier("recording-location")
                    } else { Text(note.locationStatus ?? "Location not recorded").font(.caption).foregroundStyle(.secondary) }
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
                    case .failure(let error): Text("Cannot read note: \(error.localizedDescription)").foregroundStyle(.red)
                    }
                    if let message = note.error { Text(message).font(.caption).foregroundStyle(.red) }
                }
                Section("Transcription") {
                    LabeledContent("Model", value: note.transcribedModel ?? (note.status == "complete" ? note.model : "Not transcribed"))
                        .font(.subheadline).textSelection(.enabled)
                    if note.status == "queued" || note.status == "transcribing" {
                        LabeledContent(status(note, keyStored: store.keyStored), value: note.model).font(.caption)
                    }
                    if note.transcribedModel != nil || note.status == "complete" {
                        DisclosureGroup("Machine transcript") {
                            switch Result(catching: { try String(contentsOf: library.archive.directory.appendingPathComponent("\(id).txt"), encoding: .utf8) }) {
                            case .success(let text): Text(text).textSelection(.enabled)
                            case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red)
                            }
                        }
                    }
                    Button(note.transcribedModel != nil || note.status == "complete" ? "Retranscribe…" : "Transcribe…") { transcribing = true }
                        .disabled(["recording", "transcribing"].contains(note.status))
                }
                Section { Button("Delete note", role: .destructive) { deleting = true }.disabled(["recording", "transcribing"].contains(note.status)) }
                if let error = error ?? store.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Voice note").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Edit") {
                    do { draft = try library.text(for: note); draftTitle = note.title ?? ""; editing = true }
                    catch { self.error = error.localizedDescription }
                }
            }
            .onDisappear { store.stopPlayback() }
            .alert("Rename note", isPresented: $renaming) {
                TextField("Title", text: $draftTitle)
                Button("Cancel", role: .cancel) { }
                Button("Save") { do { try library.rename(note, to: draftTitle) } catch { self.error = error.localizedDescription } }
            }
            .confirmationDialog("Delete this note?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete permanently", role: .destructive) {
                    do { try store.delete([id]); dismiss() } catch { self.error = error.localizedDescription }
                }
            } message: { Text("The recording, transcript, and edited note will be permanently deleted.") }
            .sheet(isPresented: $transcribing) { TranscribeSheet(store: store, ids: [id]) }
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

struct TranscribeSheet: View {
    @ObservedObject var store: NotesStore
    let ids: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var model = "whisper-large-v3-turbo"
    @State private var language = "en"
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Text(ids.count == 1 ? "Transcribe recording" : "Transcribe \(ids.count) recordings")
                Picker("Model", selection: $model) {
                    Text("whisper-large-v3-turbo").tag("whisper-large-v3-turbo")
                    Text("whisper-large-v3").tag("whisper-large-v3")
                }
                Picker("Language", selection: $language) { Text("English").tag("en"); Text("Detect automatically").tag("") }
                Text("Audio is sent to Groq using your key. A new transcript replaces the machine transcript; your edited note text and custom title are kept.").font(.callout).foregroundStyle(.secondary)
                if !store.keyStored { Text("Add a Groq API key in Settings first.").foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Transcribe").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Transcribe") {
                        do { try store.transcribe(ids, model: model, language: language.isEmpty ? nil : language); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!store.keyStored)
                }
            }
            .onAppear { model = store.model; language = store.language ?? "" }
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
                Section {
                    Toggle("Save recording location", isOn: $store.locationEnabled)
                    if let message = store.locationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                } footer: { Text("Capture one location when a recording starts. Coordinates stay in your local note metadata and are not sent to Groq. No background location tracking.") }
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
