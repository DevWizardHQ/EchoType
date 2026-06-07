import AppKit

/// Listens for the configured hold-to-talk hotkey via a CGEventTap.
/// Requires Accessibility permission.
final class HotkeyMonitor {
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?

    private let hotkey: HotkeyConfig
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activeHoldKeyCode: UInt16?

    init(hotkey: HotkeyConfig) {
        self.hotkey = hotkey
    }

    deinit { stop() }

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables taps that block too long; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Currently holding: only watch for the release of the primary key.
        if let holdKey = activeHoldKeyCode {
            if keyCode == holdKey {
                let released: Bool
                if let flag = HotkeyConfig.modifierFlag(for: holdKey) {
                    released = type == .flagsChanged && !event.flags.contains(flag)
                } else {
                    released = type == .keyUp
                }
                if released {
                    activeHoldKeyCode = nil
                    DispatchQueue.main.async { self.onHoldEnd?() }
                    return swallowIfNonModifier(holdKey, event: event)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Not holding: check for a press.
        if keyCode == hotkey.keyCode,
           isPress(type: type, event: event, config: hotkey),
           event.flags.contains(hotkey.requiredFlags) {
            activeHoldKeyCode = hotkey.keyCode
            DispatchQueue.main.async { self.onHoldStart?() }
            return swallowIfNonModifier(hotkey.keyCode, event: event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func isPress(type: CGEventType, event: CGEvent, config: HotkeyConfig) -> Bool {
        if let flag = HotkeyConfig.modifierFlag(for: config.keyCode) {
            return type == .flagsChanged && event.flags.contains(flag)
        }
        // Ignore key-repeat events for normal keys.
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        return type == .keyDown && !isRepeat
    }

    /// Swallow keyDown/keyUp for normal-key hotkeys so they don't type characters.
    /// Modifier-key events pass through (harmless on their own).
    private func swallowIfNonModifier(_ keyCode: UInt16, event: CGEvent) -> Unmanaged<CGEvent>? {
        HotkeyConfig.modifierFlag(for: keyCode) == nil ? nil : Unmanaged.passUnretained(event)
    }
}
