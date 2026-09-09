import AppKit

@MainActor
final class LogsView: NSView {
    private let text = NSTextView()
    private let status = NSTextField(labelWithString: "Session events and errors · up to 512 KiB retained")

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload))
        let copy = NSButton(title: "Copy Logs", target: self, action: #selector(copyLogs))
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealLogs))
        let buttons = NSStackView(views: [refresh, copy, reveal])
        buttons.orientation = .horizontal; buttons.spacing = 8
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        for view in [status, scroll, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: topAnchor, constant: 16), status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: status.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: status.leadingAnchor), buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("LogsView is created programmatically") }

    @objc func reload() {
        status.stringValue = "Session events and errors · up to 512 KiB retained"
        do { text.string = try AppLog.shared.read() }
        catch { text.string = "Could not read logs: \(error.localizedDescription)" }
        text.scrollToEndOfDocument(nil)
    }
    @objc private func copyLogs() {
        NSPasteboard.general.clearContents()
        status.stringValue = NSPasteboard.general.setString(text.string, forType: .string) ? "Logs copied" : "Could not copy logs."
    }
    @objc private func revealLogs() { NSWorkspace.shared.activateFileViewerSelecting([AppLog.shared.file]) }
}
