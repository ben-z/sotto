import AppKit

@MainActor
final class LogsView: NSView {
    private let exportFeedback = NSTextField(labelWithString: "")
    private let copyFeedback = NSTextField(labelWithString: "")
    private let export = NSButton(title: "Export Logs…", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        export.target = self; export.action = #selector(exportLogs)
        let command = NSButton(title: "Copy Terminal Command", target: self, action: #selector(copyCommand))
        let title = NSTextField(labelWithString: "Diagnostics")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let purpose = NSTextField(wrappingLabelWithString: "Save recent logs to help investigate a problem.")
        let actions = NSGridView(views: [[export, exportFeedback], [command, copyFeedback]])
        actions.rowSpacing = 12; actions.columnSpacing = 12
        actions.column(at: 0).width = 200
        actions.column(at: 0).xPlacement = .leading
        actions.column(at: 1).xPlacement = .fill
        actions.yPlacement = .center
        for feedback in [exportFeedback, copyFeedback] { feedback.textColor = .secondaryLabelColor }
        let terminalHelp = NSTextField(wrappingLabelWithString: "The terminal command displays the same logs without saving a file.")
        terminalHelp.textColor = .secondaryLabelColor
        let separator = NSBox(); separator.boxType = .separator
        let scope = NSTextField(wrappingLabelWithString: "Includes the last 24 hours of available Sotto logs. Recordings and transcripts are not included. macOS controls log retention.")
        scope.font = .systemFont(ofSize: 11)
        scope.textColor = .secondaryLabelColor
        let build = NSTextField(labelWithString: BuildInfo.diagnostics)
        build.font = .systemFont(ofSize: 11)
        build.textColor = .secondaryLabelColor
        build.isSelectable = true
        let stack = NSStackView(views: [title, purpose, actions, terminalHelp, separator, scope, build])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(8, after: scope)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16)
        ])
        for view in [purpose, actions, terminalHelp, separator, scope] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("LogsView is created programmatically") }

    func clearCopyFeedback() { copyFeedback.stringValue = "" }

    @objc private func exportLogs() {
        guard let window else { return }
        let panel = NSSavePanel()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Sotto-diagnostics-\(timestamp).txt"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.export.isEnabled = false
            self.exportFeedback.stringValue = "Exporting…"
            Task {
                defer { self.export.isEnabled = true }
                do {
                    try await DiagnosticExport.save(to: url)
                    self.exportFeedback.stringValue = "Saved"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    self.exportFeedback.stringValue = "Export failed"
                    self.showError("Could not export logs", detail: error.localizedDescription)
                }
            }
        }
    }

    @objc private func copyCommand() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(DiagnosticExport.command, forType: .string) {
            copyFeedback.stringValue = "Command copied"
        } else {
            copyFeedback.stringValue = "Copy failed"
            showError("Could not copy command", detail: "The clipboard could not be updated. Try again.")
        }
    }

    private func showError(_ title: String, detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }
}
