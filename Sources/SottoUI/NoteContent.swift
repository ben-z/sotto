import SwiftUI
import SottoCore

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

    public init(library: NoteLibrary, id: String, canEdit: Bool, editingChanged: @escaping (Bool) -> Void) {
        self.library = library; self.id = id; self.canEdit = canEdit; self.editingChanged = editingChanged
    }

    public var body: some View {
        if let note = library.notes.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Note").font(.headline)
                switch Result(catching: { try library.text(for: note) }) {
                case .success(let text):
                    if text.isEmpty { Text("No note text yet.").foregroundStyle(.secondary) }
                    else { Text(text).textSelection(.enabled) }
                    HStack {
                        ShareLink("Share note", item: text).disabled(text.isEmpty)
                        Button("Edit note", systemImage: "square.and.pencil") {
                            draft = text; error = nil; editing = true
                        }.disabled(!canEdit)
                    }.buttonStyle(.bordered)
                case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red).textSelection(.enabled)
                }
                if let message = note.error { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if note.transcribedModel != nil || note.status == "complete" || library.hasMachineTranscript(for: note) {
                    Divider()
                    Text("Model: \(note.transcribedModel ?? note.model)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    DisclosureGroup("Machine transcript") {
                        VStack(alignment: .leading, spacing: 12) {
                            switch Result(catching: { try library.machineTranscript(for: note) }) {
                            case .success(let text):
                                Text(text).textSelection(.enabled)
                                ShareLink("Share transcript", item: text)
                                if library.hasEditedText(for: note) {
                                    Button("Replace note with transcript…") { replacing = true }.buttonStyle(.bordered).disabled(!canEdit)
                                }
                            case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
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
            .confirmationDialog("Replace edited note?", isPresented: $replacing, titleVisibility: .visible) {
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
}
