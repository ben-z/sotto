import SwiftUI
import SottoCore

private struct TextRequest: Equatable, Sendable {
    let id: String
    let revision: Int
    let status: String
}

private struct NoteFiles: Sendable {
    let text: Result<String, Error>
    let hasEdits: Bool
    let hasTranscript: Bool
}

private struct LoadedText<Value> {
    let request: TextRequest
    let value: Value
}

/// Both apps expose the edited note and the latest machine output through these controls.
public struct NoteContent: View {
    @ObservedObject private var library: NoteLibrary
    private let id: String
    private let canEdit: Bool
    private let editingChanged: (Bool) -> Void
    @State private var editing = false
    @State private var replacing = false
    @State private var draft = ""
    @State private var error: String?
    @State private var transcriptExpanded = false
    @State private var noteContent: LoadedText<NoteFiles>?
    @State private var transcript: LoadedText<Result<String, Error>>?

    public init(library: NoteLibrary, id: String, canEdit: Bool, editingChanged: @escaping (Bool) -> Void) {
        self.library = library; self.id = id; self.canEdit = canEdit; self.editingChanged = editingChanged
    }

    public var body: some View {
        if let note = library.notes.first(where: { $0.id == id }) {
            let request = TextRequest(id: id, revision: library.textRevision, status: note.status)
            let files = noteContent?.request == request ? noteContent?.value : nil
            VStack(alignment: .leading, spacing: 14) {
                Text("Note").font(.headline)
                if let files { noteText(files.text) }
                else { ProgressView("Loading note…") }
                if let message = note.error { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if note.transcribedModel != nil || note.status == "complete" || files?.hasTranscript == true {
                    Divider()
                    Text("Model: \(note.transcribedModel ?? note.model)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    DisclosureGroup("Machine transcript", isExpanded: $transcriptExpanded) {
                        if transcriptExpanded {
                            VStack(alignment: .leading, spacing: 12) {
                                if let transcript, transcript.request == request {
                                    switch transcript.value {
                                    case .success(let text):
                                        Text(text).textSelection(.enabled)
                                        ShareLink("Share transcript", item: text)
                                        if files?.hasEdits == true {
                                            Button("Replace note with transcript…") { replacing = true }
                                                .buttonStyle(.bordered).disabled(!canEdit)
                                        }
                                    case .failure(let error): readError(error).accessibilityIdentifier("machine-transcript-read-error")
                                    }
                                } else { ProgressView("Loading transcript…") }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            .task(id: request) { await loadTranscript(note, request: request) }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .task(id: request) { await loadNote(note, request: request) }
            .sheet(isPresented: $editing) {
                NavigationStack {
                    VStack(alignment: .leading) {
                        TextEditor(text: $draft).font(.body).accessibilityLabel("Note text")
                        if let error { Text(error).foregroundStyle(.red) }
                    }.padding()
                    .inlineTitle("Edit note")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                do { try library.saveText(draft, for: note); editing = false }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }.noteSheetSize()
            }
            .alert("Replace edited note?", isPresented: $replacing) {
                Button("Cancel", role: .cancel) { }
                Button("Replace note", role: .destructive) {
                    do { try library.useMachineTranscript(for: note); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            } message: {
                Text("This replaces your edited text with the latest machine transcript. Future transcriptions will update the note until you edit it again.")
            }
            .onChange(of: editing) { _, value in editingChanged(value) }
            .onDisappear { editingChanged(false) }
        }
    }

    @ViewBuilder private func noteText(_ result: Result<String, Error>) -> some View {
        switch result {
        case .success(let text):
            if text.isEmpty { Text("No note text yet.").foregroundStyle(.secondary) }
            else { Text(text).textSelection(.enabled) }
            HStack {
                ShareLink("Share note", item: text).disabled(text.isEmpty)
                Button("Edit note", systemImage: "square.and.pencil") {
                    draft = text; error = nil; editing = true
                }.disabled(!canEdit)
            }.buttonStyle(.bordered)
        case .failure(let error): readError(error).accessibilityIdentifier("note-text-read-error")
        }
    }

    private func readError(_ error: Error) -> some View {
        Text(error.localizedDescription).foregroundStyle(.red).textSelection(.enabled)
    }

    private func currentRequest() -> TextRequest? {
        guard let note = library.notes.first(where: { $0.id == id }) else { return nil }
        return TextRequest(id: id, revision: library.textRevision, status: note.status)
    }

    private func loadNote(_ note: RecordingRecord, request: TextRequest) async {
        let library = library
        let files = await read {
            let text = Result { try library.text(for: note) }
            guard !Task.isCancelled else { return nil as NoteFiles? }
            return NoteFiles(text: text, hasEdits: library.hasEditedText(for: note), hasTranscript: library.hasMachineTranscript(for: note))
        }
        guard let files, !Task.isCancelled, currentRequest() == request else { return }
        noteContent = LoadedText(request: request, value: files)
    }

    private func loadTranscript(_ note: RecordingRecord, request: TextRequest) async {
        let library = library
        let result = await read { Result { try library.machineTranscript(for: note) } }
        guard let result, !Task.isCancelled, transcriptExpanded, currentRequest() == request else { return }
        transcript = LoadedText(request: request, value: result)
    }

    private func read<Value: Sendable>(_ operation: @escaping @Sendable () -> Value?) async -> Value? {
        let worker = Task.detached {
            guard !Task.isCancelled else { return nil as Value? }
            return operation()
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
    }
}

public struct RecoverNoteButton: View {
    private let action: () -> Void
    @State private var confirming = false

    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        Button("Recover note…") { confirming = true }
            .alert("Recover this note?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) { }
                Button("Recover note", action: action)
            } message: {
                Text("This recording or transcription may still be running on another device. Stop it there and let its files sync before recovering. Saved audio and text are kept.")
            }
    }
}
