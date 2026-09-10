import SwiftUI
import AppIntents
import SottoCore

@main
struct SottoNotesApp: App {
    @StateObject private var store = NotesStore.shared
    @State private var recoverySettings = false
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            Group {
                if let library = store.library { NotesView(store: store, library: library).id(ObjectIdentifier(library)) }
                else {
                    VStack {
                        ContentUnavailableView("Cannot open notes", systemImage: "exclamationmark.triangle", description: Text(store.error ?? "Loading notes"))
                        Button("Try again") { store.loadLibrary() }
                        Button("Open Settings") { recoverySettings = true }
                    }.sheet(isPresented: $recoverySettings) { SettingsView(store: store) }
                }
            }
            .onChange(of: phase) { _, value in
                if value == .background { store.suspend() }
            }
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

