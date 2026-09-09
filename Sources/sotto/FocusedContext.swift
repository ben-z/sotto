import AppKit
import ApplicationServices
import SottoCore

@MainActor
enum FocusedContext {
    static func terms() throws -> [String] {
        guard AXIsProcessTrusted() else { throw SottoError("Focused context requires Accessibility permission. Grant it or set captureFocusedContext=false.") }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw SottoError("No foreground app available for context.") }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        var text = app.localizedName ?? ""
        if let window = attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
            text += " " + (attribute(window as! AXUIElement, kAXTitleAttribute) as? String ?? "")
        }
        if let focus = attribute(element, kAXFocusedUIElementAttribute), CFGetTypeID(focus) == AXUIElementGetTypeID() {
            let field = focus as! AXUIElement
            if attribute(field, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
                throw SottoError("Context capture refused for a secure text field.")
            }
            if let selected = attribute(field, kAXSelectedTextAttribute) as? String, !selected.isEmpty {
                text += " " + selected.prefix(12000)
            } else if let value = attribute(field, kAXValueAttribute) as? String {
                text += " " + value.prefix(12000)
            }
        } else {
            throw SottoError("Foreground app does not expose focused text through Accessibility. Disable focused context to record without it.")
        }
        return Prompt.technicalTerms(from: text)
    }
}
