import SwiftUI
import AppIntents
import SottoCore

@main
struct SottoNotesApp: App {
    @StateObject private var store = NotesStore.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            Group {
                if let library = store.library { NotesView(store: store, library: library).id(ObjectIdentifier(library)) }
                else { NotesOpeningView(store: store) }
            }
            .task { await store.openLibraryIfNeeded() }
            .onChange(of: phase) { _, value in
                if value == .background { store.suspend() }
            }
        }
    }
}

private struct NoteLoadingConfiguration {
    var waitingNoticeDelay: TimeInterval = 5
}

private struct NotesOpeningView: View {
    @ObservedObject var store: NotesStore
    @State private var folderPicker = false
    @State private var folderError: String?
    @State private var copiedDetails = false
    private let configuration = NoteLoadingConfiguration()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch store.libraryState {
                case .idle:
                    ProgressView("Opening notes…")
                case .loading(let progress, let since):
                    loading(progress)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        if context.date.timeIntervalSince(since) >= configuration.waitingNoticeDelay {
                            Text("Still waiting for the notes folder…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                case .failed(let failure, let progress):
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Couldn’t open your notes").font(.title2.bold())
                    if let count = countDescription(progress) { Text(count).foregroundStyle(.secondary) }
                    Text(failureSummary(failure)).multilineTextAlignment(.center)
                    Button("Try again") {
                        copiedDetails = false; folderError = nil
                        Task { await store.loadLibrary() }
                    }.buttonStyle(.borderedProminent)
                    if failure.operation == .openFolder {
                        Button("Choose notes folder") { folderError = nil; folderPicker = true }
                    }
                    let details = [countDescription(progress), failure.technicalDetails].compactMap { $0 }.joined(separator: "\n")
                    DisclosureGroup("Technical details") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(details).font(.caption).textSelection(.enabled)
                            Button(copiedDetails ? "Details copied" : "Copy details") {
                                UIPasteboard.general.string = details
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

    @ViewBuilder private func loading(_ progress: NoteLoadProgress) -> some View {
        Text(title(progress)).font(.title2.bold())
        switch progress {
        case .opening:
            ProgressView()
        case .reading(let loaded, let total), .recovering(let loaded, let total):
            ProgressView(value: Double(loaded), total: Double(max(total, 1)))
                .accessibilityLabel(title(progress))
            if let count = countDescription(progress) {
                Text(count).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func title(_ progress: NoteLoadProgress) -> String {
        switch progress {
        case .opening, .reading: "Opening notes…"
        case .recovering: "Recovering interrupted notes…"
        }
    }

    private func countDescription(_ progress: NoteLoadProgress) -> String? {
        switch progress {
        case .opening: nil
        case .reading(let loaded, let total): "\(loaded) of \(total) notes loaded"
        case .recovering(let recovered, let total): "\(recovered) of \(total) interrupted notes recovered"
        }
    }

    private func failureSummary(_ failure: NoteLoadFailure) -> String {
        switch failure.operation {
        case .openFolder: "The notes folder couldn’t be opened. Try again, or choose the notes folder."
        case .readNote: "A note’s file couldn’t be read. Loading stopped."
        case .recoverNote: "An interrupted note’s status couldn’t be saved. Loading stopped."
        case .saveFolder: "The folder selection couldn’t be saved."
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

