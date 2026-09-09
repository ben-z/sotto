import AppKit
import SottoCore

/// Built on demand and released on close; the configuration file stays canonical.
@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate, NSTabViewDelegate, NSTextFieldDelegate {
    private let original: Configuration
    private var draft: Configuration
    private let defaults = Configuration(recordingsDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Sotto").path)
    private var resetRows: [(button: NSButton, hint: NSTextField, caption: String, matches: (Configuration) -> Bool, reset: (inout Configuration) -> Void)] = []
    private let resetAll = NSButton(title: "Reset All to Defaults", target: nil, action: nil)
    private let pathFeedback = NSTextField(labelWithString: "")
    private let duration = NSTextField(string: "")
    private let bitrate = NSTextField(labelWithString: "")
    private let saveConfiguration: (Configuration) throws -> Void
    private let didClose: () -> Void
    private let configurationURL: URL
    private var diagnostics: DiagnosticsView!
    private let tabs = NSTabView()
    private let saveButton = NSButton(title: "Save Changes", target: nil, action: nil)
    private let language = NSPopUpButton()
    private let model = NSPopUpButton()
    private let mode = NSPopUpButton()
    private let shortcut: ShortcutButton
    private let paste = NSButton(checkboxWithTitle: "Paste into the active app", target: nil, action: nil)
    private let automaticUpdates = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let trim = NSButton(checkboxWithTitle: "Trim surrounding whitespace", target: nil, action: nil)
    private let folder = NSTextField(labelWithString: "")
    private let logs = LogsView(frame: .zero)

    init(configuration: Configuration, configurationURL: URL, onSave: @escaping (Configuration) throws -> Void, onClose: @escaping () -> Void) {
        shortcut = ShortcutButton(configuration: configuration)
        draft = configuration
        original = configuration; saveConfiguration = onSave; didClose = onClose
        self.configurationURL = configurationURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sotto Settings"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        shortcut.changed = { [weak self] in self?.updateButtons() }

        addChoice(language, "Automatic detection", "")
        let locale = Locale.current
        let codes = Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 }
        for code in codes.sorted(by: { (locale.localizedString(forLanguageCode: $0) ?? $0) < (locale.localizedString(forLanguageCode: $1) ?? $1) }) {
            addChoice(language, "\(locale.localizedString(forLanguageCode: code) ?? code) (\(code))", code)
        }
        select(language, configuration.language ?? "")
        for id in ["whisper-large-v3-turbo", "whisper-large-v3"] {
            addChoice(model, id, id)
        }
        model.toolTip = "Exact model ID sent to the Groq API"
        select(model, configuration.model)
        addChoice(mode, "Hold to record, release to transcribe", "hold")
        addChoice(mode, "Press to start, press again to stop", "toggle")
        select(mode, configuration.hotkeyMode)
        automaticUpdates.state = configuration.automaticUpdateChecks ? .on : .off
        automaticUpdates.target = self; automaticUpdates.action = #selector(optionsChanged)
        automaticUpdates.toolTip = "Checks GitHub at launch and daily. Updates appear in the Sotto menu; downloads are manual."
        paste.state = configuration.paste ? .on : .off
        trim.state = configuration.trimWhitespace ? .on : .off
        paste.target = self; paste.action = #selector(optionsChanged)
        for control in [language, model, mode] { control.target = self; control.action = #selector(optionsChanged) }
        trim.target = self; trim.action = #selector(optionsChanged)
        folder.stringValue = configuration.recordingsDirectory
        folder.lineBreakMode = .byTruncatingMiddle
        folder.toolTip = configuration.recordingsDirectory
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let folderRow = NSStackView(views: [folder, choose])
        folderRow.orientation = .horizontal; folderRow.spacing = 8
        choose.setContentHuggingPriority(.required, for: .horizontal)
        let build = label(BuildInfo.version)
        build.isSelectable = true
        build.textColor = .secondaryLabelColor
        let d = defaults
        let defaultLanguage = d.language.map { "\(Locale.current.localizedString(forLanguageCode: $0) ?? $0) (\($0))" } ?? "Automatic detection"
        duration.stringValue = String(configuration.maxRecordingSeconds)
        bitrate.stringValue = "AAC · \(configuration.audioBitRate / 1000) kbps"
        duration.setAccessibilityLabel("Maximum recording duration in seconds")
        duration.delegate = self
        bitrate.textColor = .secondaryLabelColor
        let durationRow = NSStackView(views: [duration, label("seconds · 1–3,600")])
        durationRow.orientation = .horizontal; durationRow.spacing = 8
        let grid = NSGridView(views: [
            [label("Version"), build, NSGridCell.emptyContentView],
            settingRow("Language", control: language, caption: defaultLanguage, matches: { $0.language == d.language }, reset: { $0.language = d.language }),
            settingRow("Model", control: model, caption: d.model, matches: { $0.model == d.model }, reset: { $0.model = d.model }),
            settingRow("Shortcut", control: shortcut, caption: Hotkey.displayName(d), matches: { $0.hotkeyKeyCode == d.hotkeyKeyCode && $0.hotkeyModifiers == d.hotkeyModifiers }, reset: { $0.hotkeyKeyCode = d.hotkeyKeyCode; $0.hotkeyModifiers = d.hotkeyModifiers }),
            settingRow("Recording mode", control: mode, caption: "Hold to record", matches: { $0.hotkeyMode == d.hotkeyMode }, reset: { $0.hotkeyMode = d.hotkeyMode }),
            settingRow("Recordings", control: folderRow, caption: "~/Documents/Sotto", matches: { $0.recordingsURL.standardizedFileURL == d.recordingsURL.standardizedFileURL }, reset: { $0.recordingsDirectory = d.recordingsDirectory }),
            settingRow("Output", control: paste, caption: "Paste into the active app", matches: { $0.paste == d.paste }, reset: { $0.paste = d.paste }),
            settingRow("Text", control: trim, caption: "Trim surrounding whitespace", matches: { $0.trimWhitespace == d.trimWhitespace }, reset: { $0.trimWhitespace = d.trimWhitespace }),
            settingRow("Recording limit", control: durationRow, caption: "\(Int(d.maxRecordingSeconds)) seconds", matches: { $0.maxRecordingSeconds == d.maxRecordingSeconds }, reset: { $0.maxRecordingSeconds = d.maxRecordingSeconds }),
            [label("Audio format"), bitrate, NSGridCell.emptyContentView],
            settingRow("Updates", control: automaticUpdates, caption: "Automatic · launch and daily", matches: { $0.automaticUpdateChecks == d.automaticUpdateChecks }, reset: { $0.automaticUpdateChecks = d.automaticUpdateChecks })
        ])
        grid.rowSpacing = 8; grid.columnSpacing = 16
        grid.column(at: 0).width = 115
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).width = 56
        grid.column(at: 2).xPlacement = .trailing
        grid.yPlacement = .center

        let description = NSTextField(wrappingLabelWithString: "Overrides are values that differ from the defaults. Changes and resets apply only when you save. Existing recordings and your API key are kept.")
        description.textColor = .secondaryLabelColor
        resetAll.target = self; resetAll.action = #selector(resetAllSettings)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let copyPath = NSButton(title: "Copy Configuration File Path", target: self, action: #selector(copyConfigPath))
        copyPath.toolTip = configurationURL.path
        let reveal = NSButton(title: "Reveal Configuration File", target: self, action: #selector(revealConfig))
        reveal.toolTip = "Select config.json in Finder"
        let fileActions = NSStackView(views: [copyPath, reveal])
        fileActions.orientation = .horizontal; fileActions.spacing = 8
        let fileHeading = label("Configuration file")
        fileHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        let filePath = label(configurationURL.path)
        filePath.isSelectable = true; filePath.lineBreakMode = .byTruncatingMiddle
        filePath.toolTip = configurationURL.path
        filePath.font = .systemFont(ofSize: 11); filePath.textColor = .secondaryLabelColor
        pathFeedback.font = .systemFont(ofSize: 11); pathFeedback.textColor = .secondaryLabelColor
        let separator = NSBox(); separator.boxType = .separator
        let buttons = NSStackView(views: [NSView(), cancel, saveButton])
        buttons.orientation = .horizontal; buttons.spacing = 8

        let stack = NSStackView(views: [description, grid, resetAll, separator, fileHeading, filePath, fileActions, pathFeedback])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        let general = NSView()
        general.addSubview(stack)
        diagnostics = DiagnosticsView(model: { [weak self] in
            guard let self else { return configuration.model }; return self.value(self.model)
        }, needsAccessibility: { [weak self] in self?.paste.state == .on })
        let settingsTab = NSTabViewItem(identifier: "settings"); settingsTab.label = "Settings"; settingsTab.view = general
        let statusTab = NSTabViewItem(identifier: "status"); statusTab.label = "Status"; statusTab.view = diagnostics
        let logsTab = NSTabViewItem(identifier: "logs"); logsTab.label = "Logs"; logsTab.view = logs
        tabs.addTabViewItem(settingsTab); tabs.addTabViewItem(statusTab); tabs.addTabViewItem(logsTab)
        tabs.delegate = self
        for view in [tabs, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: general.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: general.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: general.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: general.bottomAnchor, constant: -16),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filePath.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabs.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        updateButtons()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("SettingsWindow is created programmatically") }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
    private func addChoice(_ control: NSPopUpButton, _ title: String, _ value: String) {
        control.addItem(withTitle: title); control.lastItem?.representedObject = value
    }
    private func select(_ control: NSPopUpButton, _ value: String) {
        if let item = control.itemArray.first(where: { $0.representedObject as? String == value }) { control.select(item) }
    }
    private func value(_ control: NSPopUpButton) -> String { control.selectedItem!.representedObject as! String }

    func captureCurrentShortcut() -> Bool {
        guard window?.isKeyWindow == true, shortcut.recording else { return false }
        shortcut.capture(original)
        return true
    }

    func showIssue(_ visible: Bool) { diagnostics.showIssue(visible) }

    func present(showStatus: Bool = false, error: String? = nil) {
        diagnostics.showIssue(error != nil)
        diagnostics.refresh()
        if showStatus { tabs.selectTabViewItem(at: 1) }
        tabView(tabs, didSelect: tabs.selectedTabViewItem)
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func chooseFolder() {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.canCreateDirectories = true; picker.allowsMultipleSelection = false
        picker.prompt = "Use Folder"
        picker.directoryURL = URL(fileURLWithPath: NSString(string: folder.stringValue).expandingTildeInPath)
        picker.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = picker.url else { return }
            self?.folder.stringValue = url.path; self?.folder.toolTip = url.path
            self?.updateButtons()
        }
    }

    @objc private func optionsChanged() { diagnostics.refresh(); updateButtons() }
    @objc private func copyConfigPath() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(configurationURL.path, forType: .string) { pathFeedback.stringValue = "Configuration file path copied" }
        else { showError("Could not copy the configuration path.") }
    }
    @objc private func revealConfig() { NSWorkspace.shared.activateFileViewerSelecting([configurationURL]) }
    func controlTextDidChange(_ notification: Notification) { updateButtons() }

    private func settingRow(_ title: String, control: NSView, caption: String,
                            matches: @escaping (Configuration) -> Bool,
                            reset: @escaping (inout Configuration) -> Void) -> [NSView] {
        let hint = label("")
        hint.font = .systemFont(ofSize: 11)
        let button = NSButton(title: "Reset", target: self, action: #selector(resetSetting(_:)))
        button.tag = resetRows.count
        button.setAccessibilityLabel("Reset \(title) to default")
        button.toolTip = "Reset \(title.lowercased()) to \(caption)"
        button.setContentHuggingPriority(.required, for: .horizontal)
        let field = NSStackView(views: [control, hint])
        field.orientation = .vertical; field.alignment = .leading; field.spacing = 3
        control.widthAnchor.constraint(equalTo: field.widthAnchor).isActive = true
        resetRows.append((button, hint, caption, matches, reset))
        return [label(title), field, button]
    }

    @objc private func resetSetting(_ sender: NSButton) {
        var config = editedConfiguration
        resetRows[sender.tag].reset(&config)
        apply(config)
    }
    @objc private func resetAllSettings() { apply(defaults) }

    private func apply(_ config: Configuration) {
        draft = config
        automaticUpdates.state = config.automaticUpdateChecks ? .on : .off
        select(language, config.language ?? "")
        select(model, config.model); select(mode, config.hotkeyMode)
        paste.state = config.paste ? .on : .off
        trim.state = config.trimWhitespace ? .on : .off
        folder.stringValue = config.recordingsDirectory; folder.toolTip = config.recordingsDirectory
        if config.maxRecordingSeconds.isFinite { duration.stringValue = String(config.maxRecordingSeconds) }
        bitrate.stringValue = "AAC · \(config.audioBitRate / 1000) kbps"
        shortcut.capture(config)
        diagnostics.refresh()
        updateButtons()
    }
    override func cancelOperation(_ sender: Any?) { /* Escape must not discard Settings edits. */ }
    @objc private func cancel() { close() }
    private var editedConfiguration: Configuration {
        var config = draft
        config.hotkeyKeyCode = shortcut.configuration.hotkeyKeyCode
        config.hotkeyModifiers = shortcut.configuration.hotkeyModifiers
        config.language = value(language).isEmpty ? nil : value(language)
        config.model = value(model); config.hotkeyMode = value(mode)
        config.recordingsDirectory = folder.stringValue
        config.trimWhitespace = trim.state == .on
        config.paste = paste.state == .on
        config.automaticUpdateChecks = automaticUpdates.state == .on
        config.maxRecordingSeconds = Double(duration.stringValue.trimmingCharacters(in: .whitespaces)) ?? .nan
        return config
    }

    @objc private func save() {
        let config = editedConfiguration
        do {
            guard (1...3600).contains(config.maxRecordingSeconds) else {
                throw SottoError("Recording limit must be a number between 1 and 3,600 seconds.")
            }
            try saveConfiguration(config); close()
        }
        catch { showError(error.localizedDescription) }
    }

    private func showError(_ message: String) {
        AppLog.shared.record(message, error: true)
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Could not complete this action"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func updateButtons() {
        let config = editedConfiguration
        for row in resetRows {
            let isDefault = row.matches(config)
            row.button.isEnabled = !isDefault
            row.hint.stringValue = "\(isDefault ? "Default" : "Override · Default"): \(row.caption)"
            row.hint.textColor = isDefault ? .secondaryLabelColor : .labelColor
        }
        resetAll.isEnabled = resetRows.contains { !$0.matches(config) } || config.audioBitRate != defaults.audioBitRate
        saveButton.isEnabled = config != original
        saveButton.keyEquivalent = tabs.selectedTabViewItem?.identifier as? String == "settings" ? "\r" : ""
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        logs.clearCopyFeedback()
        pathFeedback.stringValue = ""
        updateButtons()
        guard let window else { return }
        let tab = tabViewItem?.identifier as? String
        let height: CGFloat = tab == "settings" ? 820 : (tab == "logs" ? 400 : 650)
        var frame = window.frame
        let contentHeight = window.contentRect(forFrameRect: frame).height
        frame.origin.y += contentHeight - height
        frame.size.height += height - contentHeight
        window.setFrame(frame, display: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        diagnostics.refresh()
    }
    func windowWillClose(_ notification: Notification) {
        diagnostics.cancelCheck()
        NSApp.setActivationPolicy(.accessory)
        didClose()
    }
}
