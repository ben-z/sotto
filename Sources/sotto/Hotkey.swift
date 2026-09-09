import Carbon
import SottoCore

@MainActor
final class Hotkey {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    let action: (Bool) -> Void

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
