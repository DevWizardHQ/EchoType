import AppKit
import ApplicationServices

/// Delivers a transcript: pastes into a focused editable field, otherwise leaves
/// it on the clipboard for the user to paste manually.
enum Paster {
    private static let vKeyCode: CGKeyCode = 9

    enum Outcome {
        case pasted
        case copiedToClipboard
    }

    @discardableResult
    static func deliver(_ text: String) -> Outcome {
        if focusedElementIsEditable() {
            paste(text)
            return .pasted
        }
        copy(text)
        return .copiedToClipboard
    }

    private static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        synthesizeCmdV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if pasteboard.string(forType: .string) == text, let savedString {
                pasteboard.clearContents()
                pasteboard.setString(savedString, forType: .string)
            }
        }
    }

    private static func focusedElementIsEditable() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else {
            return false
        }
        let axElement = element as! AXUIElement

        var roleValue: AnyObject?
        if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String {
            let editableRoles: Set<String> = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                kAXComboBoxRole as String,
                "AXSearchField",
            ]
            if editableRoles.contains(role) { return true }
        }

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &settable) == .success {
            return settable.boolValue
        }
        return false
    }

    private static func synthesizeCmdV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
