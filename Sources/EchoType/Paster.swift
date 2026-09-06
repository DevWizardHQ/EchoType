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
        if hasTextTarget() {
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

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    // Recognized controls that never accept typed text — the only case where we
    // divert to the clipboard instead of pasting.
    private static let nonTextRoles: Set<String> = [
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXMenuButtonRole as String,
        kAXMenuItemRole as String,
        kAXMenuRole as String,
        kAXMenuBarRole as String,
        kAXSliderRole as String,
        kAXImageRole as String,
        "AXLink",
        "AXTab",
        kAXDisclosureTriangleRole as String,
        kAXColorWellRole as String,
    ]

    /// Whether ⌘V would land somewhere useful. Biased toward pasting: only the
    /// clear no-text cases (no focused element, or a recognized non-text control)
    /// fall through to the clipboard. Poorly-accessible apps (terminals like
    /// Warp/Ghostty) expose an opaque focused view — treat that as a text target
    /// rather than losing the paste, matching pre-1.0.3 behavior.
    // Apps whose "focus" is never a text target; dictating here goes to the
    // clipboard rather than pasting into nothing.
    private static let nonTextBundleIDs: Set<String> = [
        "com.apple.finder",
    ]

    private static func hasTextTarget() -> Bool {
        guard let axElement = focusedElement() else {
            // Some terminals (Warp, Ghostty) expose no accessibility element at
            // all. Rather than lose the paste, type into the frontmost app unless
            // it is our own app or a known non-text app (the desktop/Finder).
            let front = NSWorkspace.shared.frontmostApplication
            let bundleID = front?.bundleIdentifier ?? "?"
            let name = front?.localizedName ?? "?"
            if bundleID == Bundle.main.bundleIdentifier || nonTextBundleIDs.contains(bundleID) {
                Log.write("paste: no focused element, frontmost=\(name) — copying to clipboard")
                return false
            }
            Log.write("paste: no focused element, frontmost=\(name) — pasting anyway")
            return true
        }

        var role = "<none>"
        var roleValue: AnyObject?
        if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success,
           let r = roleValue as? String {
            role = r
        }

        let settable = isValueSettable(axElement)
        let hasCaret = hasAttribute(axElement, kAXSelectedTextRangeAttribute as String)
            || hasAttribute(axElement, kAXInsertionPointLineNumberAttribute as String)
        Log.write("paste: focused role=\(role) settable=\(settable) caret=\(hasCaret)")

        if editableRoles.contains(role) { return true }
        if settable || hasCaret { return true }
        if nonTextRoles.contains(role) { return false }
        // Unknown/opaque focus with something focused — paste rather than lose it.
        return true
    }

    /// The focused UI element. The system-wide `AXFocusedUIElement` is empty for
    /// some apps (terminals), so fall back to the frontmost application's own
    /// focused element.
    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let element = focused {
            return (element as! AXUIElement)
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var appFocused: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appFocused) == .success,
           let element = appFocused {
            return (element as! AXUIElement)
        }
        return nil
    }

    private static func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    private static func hasAttribute(_ element: AXUIElement, _ attr: String) -> Bool {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success
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
