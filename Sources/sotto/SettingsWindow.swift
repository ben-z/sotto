import AppKit
import SottoCore

/// Built on demand and released on close; the configuration file stays canonical.
@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    private let original: Configuration
    private let saveConfiguration: (Configuration) throws -> Void
    private let didClose: () -> Void
    private let configurationURL: URL
    private var diagnostics: DiagnosticsView!
    private let tabs = NSTabView()
    private let saveButton = NSButton(title: "Save Changes", target: nil, action: nil)
    private let language = NSPopUpButton()
    private let model = NSPopUpButton()
    private let mode = NSPopUpButton()
    private let paste = NSButton(checkboxWithTitle: "Paste into the active app", target: nil, action: nil)
    private let trim = NSButton(checkboxWithTitle: "Trim surrounding whitespace", target: nil, action: nil)
    private let folder = NSTextField(labelWithString: "")
    private let logs = LogsView(frame: .zero)

    init(configuration: Configuration, configurationURL: URL, onSave: @escaping (Configuration) throws -> Void, onClose: @escaping () -> Void) {
        original = configuration; saveConfiguration = onSave; didClose = onClose
        self.configurationURL = configurationURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sotto Settings"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self

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
        let grid = NSGridView(views: [
            [label("Language"), language], [label("Model"), model],
            [label("Shortcut"), label(Hotkey.displayName(configuration))],
            [label("Recording mode"), mode], [label("Recordings"), folderRow],
            [label("Output"), paste],
            [label("Text"), trim],
        ])
        grid.rowSpacing = 8; grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.yPlacement = .center

        let description = NSTextField(wrappingLabelWithString: "Changes apply when you save. All recordings are kept; choosing a new folder leaves existing files in place.")
        description.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let copyPath = NSButton(title: "Copy Config Path", target: self, action: #selector(copyConfigPath(_:)))
        copyPath.toolTip = configurationURL.path
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealConfig))
        let buttons = NSStackView(views: [copyPath, reveal, NSView(), cancel, saveButton])
        buttons.orientation = .horizontal; buttons.spacing = 8

        let stack = NSStackView(views: [description, grid])
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
    @objc private func copyConfigPath(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(configurationURL.path, forType: .string) { sender.title = "Path Copied" }
        else { showError("Could not copy the configuration path.") }
    }
    @objc private func revealConfig() { NSWorkspace.shared.activateFileViewerSelecting([configurationURL]) }
    @objc private func cancel() { close() }
    private var editedConfiguration: Configuration {
        var config = original
        config.language = value(language).isEmpty ? nil : value(language)
        config.model = value(model); config.hotkeyMode = value(mode)
        config.recordingsDirectory = folder.stringValue
        config.trimWhitespace = trim.state == .on
        config.paste = paste.state == .on
        return config
    }

    @objc private func save() {
        let config = editedConfiguration
        do { try saveConfiguration(config); close() }
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
        saveButton.isEnabled = editedConfiguration != original
        saveButton.keyEquivalent = tabs.selectedTabViewItem?.identifier as? String == "settings" ? "\r" : ""
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        updateButtons()
        if tabViewItem?.identifier as? String == "logs" { logs.reload() }
        guard let window else { return }
        let height: CGFloat = tabViewItem?.identifier as? String == "settings" ? 410 : 650
        var frame = window.frame
        let contentHeight = window.contentRect(forFrameRect: frame).height
        frame.origin.y += contentHeight - height
        frame.size.height += height - contentHeight
        window.setFrame(frame, display: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        diagnostics.refresh()
        if tabs.selectedTabViewItem?.identifier as? String == "logs" { logs.reload() }
    }
    func windowWillClose(_ notification: Notification) {
        diagnostics.cancelCheck()
        NSApp.setActivationPolicy(.accessory)
        didClose()
    }
}
