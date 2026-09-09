import AppKit
import Carbon
import SottoCore

@MainActor
final class ShortcutButton: NSButton {
    var configuration: Configuration
    var changed: (() -> Void)?
    private(set) var recording = false

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init(frame: .zero)
        bezelStyle = .rounded
        title = Hotkey.displayName(configuration)
        toolTip = "Click and press a shortcut. Escape cancels."
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) { fatalError("Created programmatically") }
    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        window?.makeFirstResponder(self)
        recording = true
        title = "Press shortcut… (Esc cancels)"
    }

    func capture(_ configuration: Configuration) {
        self.configuration.hotkeyKeyCode = configuration.hotkeyKeyCode
        self.configuration.hotkeyModifiers = configuration.hotkeyModifiers
        recording = false
        title = Hotkey.displayName(self.configuration)
        changed?()
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        title = Hotkey.displayName(configuration)
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 {
            recording = false
            title = Hotkey.displayName(configuration)
            return
        }
        let flags = event.modifierFlags
        guard !flags.intersection([.control, .option, .command]).isEmpty else {
            title = "Include Control, Option, or Command"
            return
        }
        configuration.hotkeyKeyCode = UInt32(event.keyCode)
        configuration.hotkeyModifiers = [
            (NSEvent.ModifierFlags.control, UInt32(controlKey)),
            (.option, UInt32(optionKey)), (.command, UInt32(cmdKey)), (.shift, UInt32(shiftKey))
        ].reduce(0) { $0 | (flags.contains($1.0) ? $1.1 : 0) }
        recording = false
        title = Hotkey.displayName(configuration)
        changed?()
    }
}
