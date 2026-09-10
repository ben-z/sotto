import SwiftUI

public struct TranscriptionSheet: View {
    private let count: Int
    private let keyStored: Bool
    private let transcribe: (String, String?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: String
    @State private var language: String
    @State private var error: String?

    public init(count: Int, model: String, language: String?, keyStored: Bool,
                transcribe: @escaping (String, String?) throws -> Void) {
        self.count = count; self.keyStored = keyStored; self.transcribe = transcribe
        _model = State(initialValue: model); _language = State(initialValue: language ?? "")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Text(count == 1 ? "Transcribe recording" : "Transcribe \(count) recordings")
                Picker("Model", selection: $model) {
                    Text("whisper-large-v3-turbo").tag("whisper-large-v3-turbo")
                    Text("whisper-large-v3").tag("whisper-large-v3")
                }.accessibilityIdentifier("transcription-model")
                LanguagePicker(selection: $language)
                Text("Audio is sent to Groq using your key. The result appears under Machine transcript. Your edited note and custom title are kept.")
                    .font(.callout).foregroundStyle(.secondary)
                if !keyStored { Text("Add a Groq API key in Settings first.").foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            .inlineTitle("Transcribe")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Transcribe") {
                        do { try transcribe(model, language.isEmpty ? nil : language); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!keyStored)
                }
            }
        }
        .noteSheetSize()
    }
}

extension View {
    func inlineTitle(_ title: String) -> some View {
        #if os(iOS)
        navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        #else
        safeAreaInset(edge: .top, alignment: .leading) {
            Text(title).font(.headline).padding(.horizontal, 20).padding(.top, 12)
        }
        #endif
    }
    func noteSheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: 480, idealWidth: 520, minHeight: 400, idealHeight: 480)
        #else
        self
        #endif
    }
}
