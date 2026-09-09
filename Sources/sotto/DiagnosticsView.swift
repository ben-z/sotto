import AppKit
import AVFoundation
import ApplicationServices
import SottoCore

@MainActor
final class DiagnosticsView: NSView {
    private let selectedModel: () -> String
    private let needsAccessibility: () -> Bool
    private let readiness = NSTextField(wrappingLabelWithString: "")
    private var connectionVerified = false
    private let keyStatus = NSTextField(wrappingLabelWithString: "")
    private let connection = NSTextField(wrappingLabelWithString: "Not checked. Click Check Connection to verify with Groq.")
    private let microphone = NSTextField(wrappingLabelWithString: "")
    private let accessibility = NSTextField(wrappingLabelWithString: "")
    private let check = NSButton(title: "Check Connection", target: nil, action: nil)
    private let micAction = NSButton(title: "", target: nil, action: nil)
    private var checkTask: Task<Void, Never>?
    private var checkedModel: String?

    init(model: @escaping () -> String, needsAccessibility: @escaping () -> Bool) {
        selectedModel = model; self.needsAccessibility = needsAccessibility
        super.init(frame: .zero)
        check.target = self; check.action = #selector(checkConnection)
        micAction.target = self; micAction.action = #selector(microphoneAction)
        let keyButtons = row([check, NSButton(title: "Set / Replace Key…", target: self, action: #selector(setKey))])
        let axButton = NSButton(title: "Open Accessibility Settings…", target: self, action: #selector(openAccessibility))
        let refreshButton = NSButton(title: "Refresh Status", target: self, action: #selector(refresh))
        let stack = NSStackView(views: [
            readiness, separator(), heading("1. Groq API key"), keyStatus,
            note("Storage: macOS Keychain · service Sotto.Groq · account api-key. The key is never stored in the config file or displayed here."),
            connection, keyButtons,
            note("Connection check verifies authentication and the selected model listing. It does not record audio or test transcription/quota."),
            separator(), heading("2. Permissions"), microphone, micAction, accessibility, axButton,
            separator(), refreshButton
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16)
        ])
        for view in stack.arrangedSubviews where view is NSTextField || view is NSBox {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        readiness.font = .systemFont(ofSize: 13, weight: .semibold)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("DiagnosticsView is created programmatically") }
    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 13, weight: .semibold); return label
    }
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; return label
    }
    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func row(_ views: [NSView]) -> NSStackView { let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 8; return row }

    @objc func refresh() {
        let storage = GroqKeychain.storageStatus()
        let keyStored = storage == .stored
        if !keyStored { connectionVerified = false }
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micAllowed = microphoneStatus == .authorized
        let accessibilityRequired = needsAccessibility()
        let accessibilityGranted = AXIsProcessTrusted()
        let axAllowed = !accessibilityRequired || accessibilityGranted
        let verified = connectionVerified && checkedModel == selectedModel()
        var pending: [String] = []
        if !verified { pending.append("check the Groq connection") }
        if !micAllowed { pending.append("allow microphone access") }
        if !axAllowed { pending.append("allow Accessibility or disable auto-paste/context") }
        readiness.stringValue = pending.isEmpty
            ? "Setup checks passed. Save any changed options, then use your shortcut to record."
            : "Setup needs attention: " + pending.joined(separator: "; ") + "."
        readiness.textColor = pending.isEmpty ? .systemGreen : .systemOrange
        switch storage {
        case .stored: keyStatus.stringValue = "Saved in Keychain · access is verified when used"; keyStatus.textColor = .labelColor
        case .missing: keyStatus.stringValue = "Missing · set an API key before recording"; keyStatus.textColor = .systemRed
        case .authorizationRequired: keyStatus.stringValue = "Keychain authorization needed · use Check Connection"; keyStatus.textColor = .systemOrange
        case .failure(let status): keyStatus.stringValue = "Keychain check failed (OSStatus \(status))"; keyStatus.textColor = .systemRed
        }
        if let checkedModel, checkedModel != selectedModel(), checkTask == nil {
            connection.stringValue = "Model changed. Check Connection again."; connection.textColor = .secondaryLabelColor
        }
        switch microphoneStatus {
        case .authorized: microphone.stringValue = "Microphone: Allowed · required for recording"; microphone.textColor = .systemGreen
        case .notDetermined: microphone.stringValue = "Microphone: Not requested · required for recording"; microphone.textColor = .systemOrange
        case .denied: microphone.stringValue = "Microphone: Denied · enable Sotto in System Settings"; microphone.textColor = .systemRed
        case .restricted: microphone.stringValue = "Microphone: Restricted by macOS policy"; microphone.textColor = .systemRed
        @unknown default: microphone.stringValue = "Microphone: Unknown authorization state"; microphone.textColor = .systemRed
        }
        micAction.title = microphoneStatus == .notDetermined ? "Request Microphone Access…" : "Open Microphone Settings…"
        if accessibilityGranted {
            accessibility.stringValue = accessibilityRequired
                ? "Accessibility: Allowed · required by the selected auto-paste/context options"
                : "Accessibility: Allowed · not required while auto-paste and focused context are off"
            accessibility.textColor = .systemGreen
        } else if accessibilityRequired {
            accessibility.stringValue = "Accessibility: Not authorized · required for auto-paste/context. If Sotto is already enabled in System Settings, turn it off and on again."
            accessibility.textColor = .systemRed
        } else {
            accessibility.stringValue = "Accessibility: Not granted · not required while auto-paste and focused context are off"
            accessibility.textColor = .secondaryLabelColor
        }
    }

    @objc private func checkConnection() {
        guard checkTask == nil else { return }
        let model = selectedModel()
        connectionVerified = false
        refresh()
        connection.stringValue = "Checking Groq…"; connection.textColor = .secondaryLabelColor
        check.isEnabled = false
        checkTask = Task { [weak self] in
            do {
                let key = try GroqKeychain.read()
                try await GroqClient().verifyKey(key, model: model)
                guard !Task.isCancelled else { return }
                let time = Date().formatted(date: .omitted, time: .shortened)
                self?.connection.stringValue = "Accepted by Groq at \(time) · \(model) is listed"
                self?.connectionVerified = true
                self?.connection.textColor = .systemGreen
            } catch {
                guard !Task.isCancelled else { return }
                self?.connection.stringValue = error.localizedDescription
                self?.connection.textColor = .systemRed
            }
            self?.checkedModel = model; self?.check.isEnabled = true; self?.checkTask = nil
            self?.refresh()
        }
    }

    @objc private func setKey() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Groq API Key"
        alert.informativeText = "The key is saved in macOS Keychain, not in the configuration file."
        alert.addButton(withTitle: "Save Key"); alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Groq API key"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            defer { field.stringValue = "" }
            guard response == .alertFirstButtonReturn else { return }
            do {
                try GroqKeychain.save(field.stringValue)
                self?.cancelCheck()
                self?.connection.stringValue = "Key updated. Click Check Connection to verify it."
                self?.connection.textColor = .secondaryLabelColor
            } catch { self?.connection.stringValue = error.localizedDescription; self?.connection.textColor = .systemRed }
            self?.refresh()
        }
    }

    @objc private func microphoneAction() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { [weak self] in
                _ = await Recorder.requestPermission()
                self?.refresh()
            }
        } else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
    }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func cancelCheck() { connectionVerified = false; checkTask?.cancel(); checkTask = nil; check.isEnabled = true; checkedModel = nil }
}
