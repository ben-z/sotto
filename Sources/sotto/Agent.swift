import AppKit
import ApplicationServices
import AVFoundation
import SottoCore

@MainActor
final class Agent: NSObject, NSApplicationDelegate {
    private(set) var session: Session
    private var settingsWindow: SettingsWindow?
    private var hotkey: Hotkey?
    private let statusLine = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private var recordingAction: NSMenuItem?
    private var cancelAction: NSMenuItem?
    private var copyAction: NSMenuItem?
    private var artwork: SottoStatusArtwork?
    private var item: NSStatusItem?
    private let indicator = RecordingIndicator()
    private var signals: [DispatchSourceSignal] = []
    private var pasteTarget: NSRunningApplication?
    private var lockFD: Int32 = -1

    init(configuration: Configuration) throws {
        session = try Session(configuration: configuration)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sotto", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sotto", action: #selector(quit), keyEquivalent: "q").target = self
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", Selector(("undo:")), "z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        AppLog.shared.record("Started · \(BuildInfo.diagnostics)")
        do {
            try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            lockFD = Darwin.open(Paths.support.appendingPathComponent("agent.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw SottoError("Another Sotto agent is already running, or the lock file is unavailable.") }
            hotkey = try Hotkey(keyCode: session.configuration.hotkeyKeyCode, modifiers: session.configuration.hotkeyModifiers) { [weak self] pressed in
                guard let self else { return }
                if pressed, self.settingsWindow?.captureCurrentShortcut() == true { return }
                if pressed { self.toggle() }
                else if self.session.configuration.hotkeyMode == "hold" { Task { await self.session.finish() } }
            }
            guard let resources = Bundle.main.resourceURL else { throw SottoError("Sotto app resources are missing.") }
            artwork = try SottoStatusArtwork(resourceDirectory: resources.appendingPathComponent("SottoStatus"))
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.autoenablesItems = false
            statusLine.isEnabled = false
            menu.addItem(statusLine)
            menu.addItem(.separator())
            for (title, action) in [("Start / Stop", #selector(toggle)), ("Cancel (keep audio)", #selector(cancel)), ("Copy Last Transcript", #selector(copyLastTranscript)), ("Open Recordings", #selector(openRecordings)), ("Settings…", #selector(editConfig)), ("About Sotto", #selector(about)), ("Quit", #selector(quit))] {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self; menu.addItem(entry)
                if action == #selector(toggle) { recordingAction = entry }
                if action == #selector(cancel) { cancelAction = entry }
                if action == #selector(copyLastTranscript) { copyAction = entry }
            }
            item?.menu = menu
            connectSession()
            installSignal(SIGUSR1) { [weak self] in self?.toggle() }
            installSignal(SIGUSR2) { [weak self] in self?.cancel() }
            installSignal(SIGTERM) { [weak self] in self?.quit() }
            installSignal(SIGINT) { [weak self] in self?.quit() }
            update()
            // Healthy launches stay in the menu bar; no network request or saved readiness flag.
            if GroqKeychain.storageStatus() != .stored || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized || (session.configuration.paste && !AXIsProcessTrusted()) {
                editConfig()
                settingsWindow?.present(showStatus: true)
            }
        } catch {
            fputs("Sotto startup failed: \(error.localizedDescription)\n", stderr)
            try? JSONFile.write(["state": "startup_failed", "message": error.localizedDescription], to: Paths.status)
            CLI.showStartupError(error)
            exit(1)
        }
    }

    private func installSignal(_ number: Int32, action: @escaping @MainActor () -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { action() } }
        source.resume(); signals.append(source)
    }

    @objc func toggle() {
        if session.state == .recording || session.state == .preparing { Task { await session.finish() }; return }
        guard session.state != .transcribing else { NSSound.beep(); return }
        do {
            if session.configuration.paste {
                guard AXIsProcessTrusted() else { throw SottoError("Allow Accessibility access in System Settings to use auto-paste, or turn auto-paste off in Sotto Settings.") }
            }
            pasteTarget = NSWorkspace.shared.frontmostApplication
            Task { await session.begin() }
        } catch { session.fail(error) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        editConfig()
        return true
    }

    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Sotto",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"])
        NSApp.activate()
    }

    @objc private func copyLastTranscript() {
        do { try copyToClipboard(session.lastTranscript) }
        catch { session.fail(error) }
    }

    @objc func cancel() { Task { await session.cancel() } }
    @objc func openRecordings() { NSWorkspace.shared.open(session.archive.directory) }
    @objc func editConfig() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(configuration: session.configuration, configurationURL: Paths.config, onSave: { [weak self] config in
                guard let self else { throw SottoError("Sotto is shutting down.") }
                try self.applyConfiguration(config)
            }, onClose: { [weak self] in self?.settingsWindow = nil })
        }
        settingsWindow?.present(showStatus: session.state == .error, error: session.state == .error ? session.message : nil)
    }
    private func applyConfiguration(_ config: Configuration) throws {
        guard session.state == .idle || session.state == .error else {
            throw SottoError("Finish the current recording/transcription before saving settings.")
        }
        guard try Configuration.load(from: Paths.config) == session.configuration else {
            throw SottoError("Configuration was edited outside Sotto. Restart to load those changes before saving here.")
        }
        if config.paste {
            guard AXIsProcessTrusted() else { throw SottoError("Grant Sotto Accessibility access, then click Save again.") }
        }
        let replacement = try Session(configuration: config)
        let shortcutChanged = config.hotkeyKeyCode != session.configuration.hotkeyKeyCode
            || config.hotkeyModifiers != session.configuration.hotkeyModifiers
        let newHotkey: Hotkey?
        if shortcutChanged {
            guard let action = hotkey?.action else { throw SottoError("Shortcut handler is unavailable. Restart Sotto.") }
            newHotkey = try Hotkey(keyCode: config.hotkeyKeyCode, modifiers: config.hotkeyModifiers, action: action)
        } else { newHotkey = nil }
        do { try config.save(to: Paths.config) }
        catch { newHotkey?.stop(); throw error }
        if let newHotkey { hotkey?.stop(); hotkey = newHotkey }
        session = replacement
        AppLog.shared.record("Settings saved")
        connectSession()
        update()
    }

    private func connectSession() {
        session.onChange = { [weak self] in self?.update() }
        session.onTranscript = { [weak self] text in try self?.deliver(text) }
    }

    @objc func quit() {
        Task {
            await session.cancel()
            // Let an in-flight cancelled upload persist its final metadata.
            while session.state == .transcribing { try? await Task.sleep(for: .milliseconds(50)) }
            do { try JSONFile.write(["state": "stopped", "message": "Agent exited"], to: Paths.status) }
            catch { AppLog.shared.record("Cannot save shutdown status: \(error.localizedDescription)", error: true) }
            AppLog.shared.record("Sotto stopped")
            NSApp.terminate(nil)
        }
    }

    private func update() {
        if let item {
            artwork?.apply(SottoStatusArtwork.State(rawValue: session.state.rawValue)!, to: item)
            item.button?.imagePosition = .imageLeading
            item.button?.setAccessibilityValue(session.message)
        }
        switch session.state {
        case .idle: statusLine.title = "Ready · " + Hotkey.displayName(session.configuration)
        case .preparing: statusLine.title = "Preparing microphone…"
        case .recording: statusLine.title = "Recording…"
        case .transcribing: statusLine.title = "Transcribing…"
        case .error: statusLine.title = "Needs attention · open Settings"
        }
        statusLine.toolTip = session.message
        let capturing = session.state == .recording || session.state == .preparing
        recordingAction?.title = capturing ? "Stop Recording" : "Start Recording · " + Hotkey.displayName(session.configuration)
        recordingAction?.isEnabled = session.state != .transcribing
        cancelAction?.isEnabled = capturing || session.state == .transcribing
        copyAction?.isEnabled = !session.lastTranscript.isEmpty
        item?.button?.toolTip = session.message
        item?.button?.title = session.state == .recording ? " REC" : ""
        indicator.update(session.state)
        settingsWindow?.showIssue(session.state == .error)
        AppLog.shared.record(session.state == .error ? session.message : "\(session.state.rawValue): \(session.message)", error: session.state == .error)
        do { try JSONFile.write(["state": session.state.rawValue, "message": session.message], to: Paths.status) }
        catch { AppLog.shared.record("Cannot save status: \(error.localizedDescription)", error: true) }
        if session.state == .error {
            NSSound.beep()
            editConfig()
        }
    }

    private func copyToClipboard(_ text: String) throws {
        guard !text.isEmpty else { throw SottoError("There is no transcript to copy yet.") }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { throw SottoError("Cannot write transcript to clipboard.") }
    }

    private func deliver(_ text: String) throws {
        try copyToClipboard(text)
        guard session.configuration.paste else { return }
        guard AXIsProcessTrusted() else { throw SottoError("Accessibility permission missing; transcript is on clipboard.") }
        guard let pasteTarget, NSWorkspace.shared.frontmostApplication?.processIdentifier == pasteTarget.processIdentifier else {
            throw SottoError("Foreground app changed while recording; transcript is on clipboard. Paste manually.")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { throw SottoError("Cannot create paste event; transcript is on clipboard.") }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}
