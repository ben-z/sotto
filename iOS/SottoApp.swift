import SwiftUI
import AppIntents
import SottoCore

@main
struct SottoNotesApp: App {
    @StateObject private var store = NotesStore.shared
    @Environment(\.scenePhase) private var phase
    @State private var refreshOnForeground = false
    var body: some Scene {
        WindowGroup {
            Group {
                if let library = store.library { NotesView(store: store, library: library).id(ObjectIdentifier(library)) }
                else { NotesOpeningView(store: store) }
            }
            .task { await store.openLibraryIfNeeded() }
            .onChange(of: phase) { _, value in
                if value == .background { store.suspend(); refreshOnForeground = true }
                if value == .active && refreshOnForeground {
                    refreshOnForeground = false
                    Task { await store.refreshAfterForegrounding() }
                }
            }
        }
    }
}

private struct NotesOpeningView: View {
    @ObservedObject var store: NotesStore
    @State private var folderPicker = false
    @State private var folderError: String?
    @State private var copiedDetails = false
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch store.libraryState {
                case .idle, .loading:
                    ProgressView("Opening notes folder…")
                case .failed(let failure, _):
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Couldn’t open your notes").font(.title2.bold())
                    Text("The notes folder couldn’t be opened. Try again, or choose the notes folder.").multilineTextAlignment(.center)
                    Button("Try again") {
                        copiedDetails = false; folderError = nil
                        Task { await store.loadLibrary() }
                    }.buttonStyle(.borderedProminent)
                    Button("Choose notes folder") { folderError = nil; folderPicker = true }
                    DisclosureGroup("Technical details") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(failure.technicalDetails).font(.caption).textSelection(.enabled)
                            Button(copiedDetails ? "Details copied" : "Copy details") {
                                UIPasteboard.general.string = failure.technicalDetails
                                copiedDetails = true
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                case .ready:
                    EmptyView()
                }
                if let folderError { Text(folderError).foregroundStyle(.red) }
            }
            .frame(maxWidth: 440).padding(32)
            .frame(maxWidth: .infinity)
        }
        .safeAreaPadding(.top, 80)
        .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder]) { result in
            do { try store.selectFolder(result.get()) }
            catch { folderError = error.localizedDescription }
        }
    }
}

struct RecordVoiceNote: AppIntent {
    static let title: LocalizedStringResource = "Record a voice note"
    static let description = IntentDescription("Open Sotto and start recording. Run again to stop and save.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        await NotesStore.shared.toggleRecording()
        if let error = NotesStore.shared.error { throw RecordingIntentError(message: error) }
        return .result()
    }
}

private struct RecordingIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

struct SottoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordVoiceNote(), phrases: ["Record a note in \(.applicationName)"], shortTitle: "Record a voice note", systemImageName: "mic")
    }
}
