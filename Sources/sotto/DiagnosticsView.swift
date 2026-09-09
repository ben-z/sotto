import AppKit
import AVFoundation
import ApplicationServices
import SottoCore

@MainActor
final class DiagnosticsView: NSView {
    private let selectedModel: () -> String
    private let needsAccessibility: () -> Bool
    private let issue = NSTextField(wrappingLabelWithString: "The last action failed. Open Logs for details.")
    private let readiness = NSTextField(wrappingLabelWithString: "")
    private var connectionVerified = false
    private var replacingKey = false
    private let keyStatus = NSTextField(wrappingLabelWithString: "")
    private let connection = NSTextField(wrappingLabelWithString: "Not checked. Click Check Connection to verify with Groq.")
    private let microphone = NSTextField(wrappingLabelWithString: "")
    private let accessibility = NSTextField(wrappingLabelWithString: "")
    private let keyField = NSSecureTextField(string: "")
    private let cancelReplacement = NSButton(title: "Cancel", target: nil, action: nil)
    private let saveKey = NSButton(title: "Save & Check", target: nil, action: nil)
    private let deleteKey = NSButton(title: "Delete Key…", target: nil, action: nil)
    private let check = NSButton(title: "Check Connection", target: nil, action: nil)
    private let micAction = NSButton(title: "", target: nil, action: nil)
    private var checkTask: Task<Void, Never>?
    private var checkedModel: String?

    init(model: @escaping () -> String, needsAccessibility: @escaping () -> Bool) {
        selectedModel = model; self.needsAccessibility = needsAccessibility
        super.init(frame: .zero)
        check.target = self; check.action = #selector(checkConnection)
        micAction.target = self; micAction.action = #selector(microphoneAction)
        keyField.placeholderString = "Paste your Groq API key"
        keyField.setAccessibilityLabel("Groq API key")
        keyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        saveKey.target = self; saveKey.action = #selector(setKey)
        keyField.target = self; keyField.action = #selector(setKey)
        (keyField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        cancelReplacement.target = self; cancelReplacement.action = #selector(cancelReplacingKey)
        let keyEntry = row([keyField, saveKey, cancelReplacement])
        keyEntry.distribution = .fill
        let getKey = NSButton(title: "Get a Groq API key ↗", target: self, action: #selector(openGroqKeys))
        deleteKey.target = self; deleteKey.action = #selector(confirmDeleteKey)
        let keyButtons = row([check, getKey, deleteKey])
        let axButton = NSButton(title: "Open Accessibility Settings…", target: self, action: #selector(openAccessibility))
        axButton.toolTip = "Enable Sotto in Privacy & Security > Accessibility."
        let refreshButton = NSButton(title: "Refresh Status", target: self, action: #selector(refresh))
        let stack = NSStackView(views: [
            issue, readiness, separator(), heading("Groq connection"), keyStatus,
            note("Your key stays in this device’s Keychain, never in your config file."),
            keyEntry, connection, keyButtons,
            note("Audio goes directly to Groq using your account. All recordings stay in your chosen folder."),
            note("Connection check verifies authentication and the selected model listing. It does not record audio or test transcription/quota."),
            separator(), heading("Permissions"), microphone, micAction, accessibility, axButton,
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
        keyEntry.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for view in stack.arrangedSubviews where view is NSTextField || view is NSBox {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        keyStatus.toolTip = "macOS Keychain · service Sotto.Groq · account api-key"
        issue.textColor = .systemRed
        issue.isHidden = true
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

    func showIssue(_ visible: Bool) { issue.isHidden = !visible }

    @objc func refresh() {
        let storage = GroqKeychain.storageStatus()
        let keyStored = storage == .stored
        if !keyStored {
            connectionVerified = false
            checkedModel = nil
        }
        let showSavedKey = keyStored && !replacingKey
        keyField.placeholderString = showSavedKey ? "•••••••• · Saved in Keychain" : "Paste your Groq API key"
        keyField.setAccessibilityLabel(showSavedKey ? "API key saved in Keychain" : "Groq API key")
        keyField.isEnabled = !showSavedKey && checkTask == nil
        saveKey.title = showSavedKey ? "Replace Key…" : "Save & Check"
        saveKey.isEnabled = checkTask == nil
        cancelReplacement.isHidden = !replacingKey
        cancelReplacement.isEnabled = checkTask == nil
        check.isEnabled = checkTask == nil && storage != .missing
        deleteKey.isHidden = storage == .missing
        deleteKey.isEnabled = checkTask == nil
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micAllowed = microphoneStatus == .authorized
        let accessibilityRequired = needsAccessibility()
        let accessibilityGranted = AXIsProcessTrusted()
        let axAllowed = !accessibilityRequired || accessibilityGranted
        let verified = connectionVerified && checkedModel == selectedModel()
        var pending: [String] = []
        if storage == .missing { pending.append("add a Groq key") }
        else if !keyStored { pending.append("check Keychain access") }
        if !micAllowed { pending.append("allow microphone access") }
        if !axAllowed { pending.append("allow Accessibility or disable auto-paste") }
        if !pending.isEmpty {
            readiness.stringValue = "To get started: " + pending.joined(separator: "; ") + "."
            readiness.textColor = .systemOrange
        } else if verified {
            readiness.stringValue = "Ready to record. Groq connection verified."
            readiness.textColor = .systemGreen
        } else {
            readiness.stringValue = "Key and permissions are in place. Check Connection to verify Groq."
            readiness.textColor = .labelColor
        }
        switch storage {
        case .stored: keyStatus.stringValue = "Key saved in Keychain"; keyStatus.textColor = .labelColor
        case .missing: keyStatus.stringValue = "Add your key to connect Sotto to Groq"; keyStatus.textColor = .systemRed
        case .authorizationRequired: keyStatus.stringValue = "Keychain authorization needed · use Check Connection"; keyStatus.textColor = .systemOrange
        case .failure(let status): keyStatus.stringValue = "Keychain check failed (OSStatus \(status))"; keyStatus.textColor = .systemRed
        }
        if let checkedModel, checkedModel != selectedModel(), checkTask == nil {
            connectionVerified = false
            self.checkedModel = nil
            connection.stringValue = "Model changed. Check Connection again."; connection.textColor = .secondaryLabelColor
        }
        switch microphoneStatus {
        case .authorized: microphone.stringValue = "Microphone: Allowed · required for recording"; microphone.textColor = .systemGreen
        case .notDetermined: microphone.stringValue = "Microphone: Allow access to record your voice"; microphone.textColor = .systemOrange
        case .denied: microphone.stringValue = "Microphone: Denied · enable Sotto in System Settings"; microphone.textColor = .systemRed
        case .restricted: microphone.stringValue = "Microphone: Restricted by macOS policy"; microphone.textColor = .systemRed
        @unknown default: microphone.stringValue = "Microphone: Unknown authorization state"; microphone.textColor = .systemRed
        }
        micAction.title = microphoneStatus == .notDetermined ? "Request Microphone Access…" : "Open Microphone Settings…"
        if accessibilityGranted {
            accessibility.stringValue = accessibilityRequired
                ? "Accessibility: Allowed · required for auto-paste"
                : "Accessibility: Allowed · not required while auto-paste is off"
            accessibility.textColor = .systemGreen
        } else if accessibilityRequired {
            accessibility.stringValue = "Accessibility: Allow access for auto-paste, or turn auto-paste off in Settings."
            accessibility.textColor = .systemRed
        } else {
            accessibility.stringValue = "Accessibility: Not needed · auto-paste is off"
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
        deleteKey.isEnabled = false
        saveKey.isEnabled = false
        keyField.isEnabled = false
        cancelReplacement.isEnabled = false
        checkTask = Task { [weak self] in
            do {
                let key = try GroqKeychain.read()
                try await GroqClient().verifyKey(key, model: model)
                guard !Task.isCancelled else { return }
                let time = Date().formatted(date: .omitted, time: .shortened)
                self?.connection.stringValue = "Accepted by Groq at \(time) · \(model) is listed"
                AppLog.shared.record("Groq connection verified · \(model)")
                self?.connectionVerified = true
                self?.connection.textColor = .systemGreen
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.shared.record("Groq connection check failed: \(error.localizedDescription)", error: true)
                self?.connection.stringValue = error.localizedDescription
                self?.connection.textColor = .systemRed
            }
            self?.checkedModel = model; self?.check.isEnabled = true; self?.checkTask = nil
            self?.saveKey.isEnabled = true; self?.keyField.isEnabled = true
            self?.refresh()
        }
    }

    @objc private func setKey() {
        guard checkTask == nil else { return }
        if GroqKeychain.storageStatus() == .stored && !replacingKey {
            replacingKey = true
            refresh()
            window?.makeFirstResponder(keyField)
            return
        }
        do {
            try GroqKeychain.save(keyField.stringValue)
            AppLog.shared.record("Groq key saved to Keychain")
            keyField.stringValue = ""
            replacingKey = false
            checkConnection()
        } catch {
            AppLog.shared.record("Could not save Groq key: \(error.localizedDescription)", error: true)
            connection.stringValue = error.localizedDescription
            connection.textColor = .systemRed
            refresh()
        }
    }

    @objc private func cancelReplacingKey() {
        replacingKey = false
        keyField.stringValue = ""
        connectionVerified = false
        checkedModel = nil
        connection.stringValue = "Saved key unchanged. Click Check Connection to verify with Groq."
        connection.textColor = .secondaryLabelColor
        refresh()
    }

    @objc private func confirmDeleteKey() {
        guard checkTask == nil, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the saved Groq key?"
        alert.informativeText = "This removes Sotto’s key from this device’s Keychain. It does not revoke the key at Groq or delete recordings. You will need to add a key again to transcribe."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Key")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            do {
                try GroqKeychain.delete()
                AppLog.shared.record("Groq key deleted from Keychain")
                self.cancelCheck()
                self.replacingKey = false
                self.connection.stringValue = "Key deleted from this device. Add a key to transcribe."
                self.connection.textColor = .secondaryLabelColor
            } catch {
                AppLog.shared.record("Could not delete Groq key: \(error.localizedDescription)", error: true)
                self.connection.stringValue = error.localizedDescription
                self.connection.textColor = .systemRed
            }
            self.refresh()
        }
    }

    @objc private func openGroqKeys() {
        guard NSWorkspace.shared.open(URL(string: "https://console.groq.com/keys")!) else {
            connection.stringValue = "Could not open your browser. Visit console.groq.com/keys to create a key."
            connection.textColor = .systemRed
            return
        }
    }

    @objc private func microphoneAction() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { [weak self] in
                let granted = await Recorder.requestPermission()
                AppLog.shared.record(granted ? "Microphone access allowed" : "Microphone access denied", error: !granted)
                self?.refresh()
            }
        } else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
    }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func cancelCheck() { keyField.stringValue = ""; saveKey.isEnabled = true; keyField.isEnabled = true; connectionVerified = false; checkTask?.cancel(); checkTask = nil; check.isEnabled = true; checkedModel = nil }
}
