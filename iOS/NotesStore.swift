import AVFoundation
import Combine
import Network
import OSLog
import SottoCore
import UIKit

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
    private let bookmarkURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sotto/folder.bookmark")
    var model: String { UserDefaults.standard.string(forKey: "notes.model") ?? "whisper-large-v3-turbo" }
    var language: String? {
        let value = UserDefaults.standard.string(forKey: "notes.language") ?? "en"
        return value.isEmpty ? nil : value
    }

    override init() {
        super.init()
        loadLibrary()
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

    func loadLibrary() {
        guard library == nil else { return }
        scopedFolder?.stopAccessingSecurityScopedResource(); scopedFolder = nil
        error = nil
        do {
            var directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
            if FileManager.default.fileExists(atPath: bookmarkURL.path) {
                var stale = false
                let folder = try URL(resolvingBookmarkData: Data(contentsOf: bookmarkURL), bookmarkDataIsStale: &stale)
                guard !stale, folder.startAccessingSecurityScopedResource() else { throw SottoError("The saved recording folder is unavailable. Restore its access before opening notes.") }
                scopedFolder = folder; directory = folder
            }
            library = try NoteLibrary(directory: directory)
        } catch { self.error = error.localizedDescription }
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
            try FileManager.default.createDirectory(at: bookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bookmark.write(to: bookmarkURL, options: .atomic)
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

