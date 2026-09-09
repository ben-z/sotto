import Carbon
import SottoCore

@MainActor
final class Hotkey {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    let action: (Bool) -> Void

    static func displayName(_ configuration: Configuration) -> String {
        let flags = configuration.hotkeyModifiers
        let modifiers = [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
                         (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
            .filter { flags & $0.0 != 0 }.map(\.1).joined()
        let keys: [UInt32: String] = [0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
            6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
            15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
            37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 49: "Space"]
        return modifiers + (keys[configuration.hotkeyKeyCode] ?? "Key \(configuration.hotkeyKeyCode)")
    }

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping (Bool) -> Void) throws {
        self.action = action
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let instance = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { instance.action(pressed) }
            return noErr
        }, 2, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw SottoError("Cannot install hotkey handler (OSStatus \(status)).") }
        let result = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x5354544F, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        guard result == noErr else {
            if let handler { RemoveEventHandler(handler) }; handler = nil
            throw SottoError("Hotkey unavailable or already registered (OSStatus \(result)). Change hotkeyKeyCode/hotkeyModifiers in config.json.")
        }
    }
}
