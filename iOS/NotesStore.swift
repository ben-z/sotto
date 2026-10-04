import AVFoundation
import Combine
import CoreLocation
import OSLog
import SottoCore
import UIKit

@MainActor
final class NotesStore: NSObject, ObservableObject, AVAudioPlayerDelegate, CLLocationManagerDelegate {
    static let shared = NotesStore()
    enum LibraryState {
        case idle
        case loading(NoteLoadProgress, since: Date)
        case failed(NoteLoadFailure, progress: NoteLoadProgress)
        case ready(NoteLibrary)
    }
    @Published private(set) var libraryState: LibraryState = .idle
    var library: NoteLibrary? {
        if case .ready(let library) = libraryState { return library }
        return nil
    }
    var openingLibrary: Bool {
        if case .loading = libraryState { return true }
        return false
    }
    private var openingTask: Task<Void, Never>?
    private var selectedFolder: URL?
    private var folder: NotesFolder?
    @Published var recording: RecordingRecord?
    @Published var preparing = false
    @Published var error: String?
    @Published var playingID: String?
    @Published var keyStored = false
    @Published var locationEnabled = UserDefaults.standard.bool(forKey: "notes.location") {
        didSet {
            UserDefaults.standard.set(locationEnabled, forKey: "notes.location")
            if locationEnabled { locationManager.requestWhenInUseAuthorization() }
            else {
                for request in locationRequests.values { request.manager.delegate = nil; request.manager.stopUpdatingLocation() }
                locationRequests.removeAll(); locationMessage = nil
            }
        }
    }
    @Published var locationMessage: String?
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return manager
    }()
    private var locationRequests: [ObjectIdentifier: (manager: CLLocationManager, noteID: String)] = [:]
    private let recorder = Recorder()
    private let log = Logger(subsystem: "dev.sotto.notes", category: "audio")
    private var player: AVAudioPlayer?
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private let bookmarkURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sotto/folder.bookmark")
    var model: String { UserDefaults.standard.string(forKey: "notes.model") ?? "whisper-large-v3-turbo" }
    var maxRecordingSeconds: Double {
        let saved = UserDefaults.standard.double(forKey: "notes.maxRecordingSeconds")
        return Configuration.recordingSecondsRange.contains(saved) ? saved : Configuration.defaultMaxRecordingSeconds
    }
    var language: String? {
        let value = UserDefaults.standard.string(forKey: "notes.language") ?? "en"
        return value.isEmpty ? nil : value
    }

    override init() {
        super.init()
        refreshKey()
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        recorder.onUnexpectedStop = { [weak self] message in
            self?.finish(recordingError: message)
        }

    }

    func openLibraryIfNeeded() async {
        if case .idle = libraryState { await loadLibrary() }
        else if let openingTask { await openingTask.value }
    }

    func loadLibrary() async {
        guard library == nil else { return }
        await startOpening().value
    }

    private func startOpening() -> Task<Void, Never> {
        if let openingTask { return openingTask }
        libraryState = .loading(.opening, since: Date())
        log.notice("Opening notes")
        let selectedFolder = selectedFolder
        let bookmarkURL = bookmarkURL
        let task = Task {
            defer { openingTask = nil }
            var progress = NoteLoadProgress.opening
            do {
                let destination = try await Task.detached {
                    try NotesFolder(selected: selectedFolder, bookmarkURL: bookmarkURL)
                }.value
                let library = try await NoteLibrary.open(directory: destination.url) { update in
                    progress = update
                    self.libraryState = .loading(update, since: Date())
                }
                if selectedFolder != nil {
                    try await Task.detached { try destination.saveBookmark(to: bookmarkURL) }.value
                }
                folder = destination
                libraryState = .ready(library)
                log.notice("Opened \(library.notes.count) notes")
            } catch {
                let failure: NoteLoadFailure
                if let reported = error as? NoteLoadFailure { failure = reported }
                else { failure = NoteLoadFailure(operation: .openFolder, url: bookmarkURL, underlying: error) }
                log.error("Opening notes failed: \(failure.technicalDetails, privacy: .public)")
                libraryState = .failed(failure, progress: progress)
            }
        }
        openingTask = task
        return task
    }

    @objc nonisolated private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor [weak self] in self?.finish(recordingError: nil) }
    }

    func refreshKey() {
        switch GroqKeychain.storageStatus() {
        case .stored, .authorizationRequired: keyStored = true
        case .missing: keyStored = false
        case .failure(let code): error = "Keychain could not be read (\(code))."
        }
    }

    func toggleRecording() async {
        if recording != nil { finish(recordingError: nil); return }
        guard !preparing else { return }
        preparing = true; error = nil
        defer { preparing = false }
        await openLibraryIfNeeded()
        guard let library else {
            let message: String
            if case .failed(let failure, _) = libraryState {
                message = failure.localizedDescription
            } else {
                message = "The notes library is not ready after opening. Open Sotto to review the error and try again."
            }
            error = message
            log.error("Recording could not start: \(message, privacy: .public)")
            return
        }
        stopPlayback()
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
            captureLocation(for: note)
            log.notice("Recording \(note.id, privacy: .public)")
            let maximumSeconds = maxRecordingSeconds
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(maximumSeconds), tolerance: .zero) }
                catch { return }
                self?.finish(recordingError: nil)
            }
        } catch {
            self.error = error.localizedDescription
            log.error("Recording could not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finish(recordingError: String?) {
        guard let note = recording, let library else { return }
        deadline?.cancel(); deadline = nil; error = nil
        defer { recording = nil }
        do {
            try library.finishRecording(note, recordingError: recordingError, stop: { try recorder.stop() })
            log.notice("Saved audio \(note.id, privacy: .public)")
            process([note.id])
        } catch { self.error = error.localizedDescription }
    }

    func process(_ ids: Set<String>) {
        guard let library else { return }
        guard worker == nil else { error = "Audio saved. Wait for the current transcription, then select Transcribe."; return }
        guard keyStored else { error = "Audio saved. Add a Groq key in Settings, then select Transcribe."; return }
        guard UIApplication.shared.applicationState == .active else { error = "Audio saved. Open the note and select Transcribe."; return }
        worker = Task { [weak self] in
            await library.process(ids: ids, key: { try GroqKeychain.read() }) { url, key, note in
                try await GroqClient().transcribe(file: url, key: key, model: note.model, language: note.language, prompt: note.prompt)
            }
            self?.worker = nil
        }
    }

    func suspend() {
        // Active recording continues in the background; cancelled uploads require retry.
        stopPlayback(); worker?.cancel()
    }

    func selectFolder(_ url: URL) throws {
        guard !openingLibrary else { throw SottoError("Wait for the notes folder to finish opening.") }
        guard recording == nil, !preparing, worker == nil else { throw SottoError("Finish recording and transcription before changing folders.") }
        guard locationRequests.isEmpty else { throw SottoError("Wait for recording location capture to finish before changing folders.") }
        error = nil
        stopPlayback()
        selectedFolder = url
        _ = startOpening()
    }

    func deleteKey() throws {
        try GroqKeychain.delete(); refreshKey(); worker?.cancel()
    }

    func transcribe(_ ids: Set<String>, model: String, language: String?) throws {
        guard worker == nil else { throw SottoError("Wait for the current transcription to finish.") }
        guard keyStored, let library else { throw SottoError("Add a Groq API key in Settings first.") }
        try library.transcribe(ids, model: model, language: language)
        process(ids)
    }

    func delete(_ ids: Set<String>) throws {
        if let playingID, ids.contains(playingID) { stopPlayback() }
        try library?.delete(ids)
    }

    private func captureLocation(for note: RecordingRecord) {
        guard locationEnabled else { return }
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationRequests[ObjectIdentifier(manager)] = (manager, note.id)
        manager.delegate = self
    }

    private func saveLocation(_ location: RecordingLocation?, message: String?, requestID: ObjectIdentifier) {
        guard let request = locationRequests.removeValue(forKey: requestID) else { return }
        request.manager.delegate = nil
        locationMessage = message
        guard let library, var note = library.notes.first(where: { $0.id == request.noteID }) else { return }
        note.location = location; note.locationStatus = message
        do { try library.save(note) } catch { self.error = "Cannot save location: \(error.localizedDescription)" }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let requestID = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in
            guard let self, self.locationEnabled else { return }
            if let request = self.locationRequests[requestID] {
                switch request.manager.authorizationStatus {
                case .authorizedAlways, .authorizedWhenInUse: request.manager.requestLocation()
                case .notDetermined: request.manager.requestWhenInUseAuthorization()
                default: self.saveLocation(nil, message: "Location access is disabled in iPhone Settings.", requestID: requestID)
                }
                return
            }
            switch self.locationManager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.locationMessage = nil
            case .denied, .restricted: self.locationMessage = "Location access is disabled in iPhone Settings."
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let requestID = ObjectIdentifier(manager)
        let location = locations.last
        Task { @MainActor [weak self] in
            guard let self, self.locationEnabled else { return }
            guard let location, location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSinceNow) < 60 else {
                self.saveLocation(nil, message: "Location was unavailable when this recording started.", requestID: requestID); return
            }
            self.saveLocation(RecordingLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, accuracyMeters: location.horizontalAccuracy), message: nil, requestID: requestID)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let requestID = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in
            self?.saveLocation(nil, message: "Location unavailable: \(error.localizedDescription)", requestID: requestID)
        }
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

/// Keeps folder access alive for the full load and the lifetime of the open library.
private final class NotesFolder: Sendable {
    let url: URL
    private let scoped: Bool

    init(selected: URL?, bookmarkURL: URL) throws {
        var target = selected
        do {
            if target == nil {
                let data: Data
                do { data = try Data(contentsOf: bookmarkURL) }
                catch CocoaError.fileReadNoSuchFile {
                    url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
                    scoped = false
                    return
                }
                var stale = false
                target = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
                guard !stale else { throw SottoError("The saved folder access has expired. Choose the notes folder again.") }
            }
            guard let target, target.startAccessingSecurityScopedResource() else {
                throw SottoError("Access to the notes folder was denied. Choose the folder again to restore access.")
            }
            url = target
            scoped = true
        } catch { throw NoteLoadFailure(operation: .openFolder, url: target ?? bookmarkURL, underlying: error) }
    }

    func saveBookmark(to bookmarkURL: URL) throws {
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            try FileManager.default.createDirectory(at: bookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bookmark.write(to: bookmarkURL, options: .atomic)
        } catch { throw NoteLoadFailure(operation: .saveFolder, url: bookmarkURL, underlying: error) }
    }

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}
