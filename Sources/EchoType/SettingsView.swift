import SwiftUI
import ServiceManagement

struct SettingsView: View {
    weak var appDelegate: AppDelegate?

    @State private var dictateHotkey = Settings.dictateHotkey
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var policy = Settings.webviewPolicy
    @State private var keepWarm = Settings.keepWarmDuration
    @State private var autoUpdates = Settings.autoCheckUpdates

    var body: some View {
        Form {
            Section("Hotkey (hold to talk)") {
                HotkeyRecorderRow(title: "Dictate", hotkey: $dictateHotkey) {
                    Settings.dictateHotkey = $0
                    appDelegate?.startHotkeyMonitor()
                }
            }

            Section("ChatGPT session") {
                Picker("Keep ChatGPT ready", selection: $policy) {
                    Text("Always (instant dictation)").tag(WebviewPolicy.alwaysReady)
                    Text("Only while in use").tag(WebviewPolicy.keepWarm)
                }
                .onChange(of: policy) { _, value in
                    Settings.webviewPolicy = value
                    appDelegate?.webviewPolicyChanged()
                }
                if policy == .keepWarm {
                    Picker("Unload after idle for", selection: $keepWarm) {
                        Text("3 minutes").tag(TimeInterval(180))
                        Text("10 minutes").tag(TimeInterval(600))
                        Text("30 minutes").tag(TimeInterval(1800))
                        Text("1 hour").tag(TimeInterval(3600))
                    }
                    .onChange(of: keepWarm) { _, value in
                        Settings.keepWarmDuration = value
                        appDelegate?.webviewPolicyChanged()
                    }
                }
                Text(policy == .alwaysReady
                     ? "The hidden ChatGPT page stays loaded (~150–250 MB) so dictation starts instantly."
                     : "The hidden ChatGPT page loads on first use and unloads after the idle time above (~30 MB idle). The first dictation after idle waits a few seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoUpdates)
                    .onChange(of: autoUpdates) { _, enabled in
                        Settings.autoCheckUpdates = enabled
                        if enabled {
                            UpdateManager.shared.startAutomaticChecks()
                        } else {
                            UpdateManager.shared.stopAutomaticChecks()
                        }
                    }
                HStack {
                    Text("Version")
                    Spacer()
                    Text(UpdateManager.currentVersion)
                        .foregroundStyle(.secondary)
                    Button("Check Now") {
                        UpdateManager.shared.checkForUpdates(userInitiated: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Hotkey recorder

private struct HotkeyRecorderRow: View {
    let title: String
    @Binding var hotkey: HotkeyConfig
    let onChange: (HotkeyConfig) -> Void

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(isRecording ? "Press a key…" : hotkey.displayString) {
                isRecording ? stopRecording() : startRecording()
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .red : nil)
        }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                // Capture a modifier key only on press (its flag is set), not release.
                let keyCode = event.keyCode
                if let flag = HotkeyConfig.modifierFlag(for: keyCode),
                   CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).contains(flag) {
                    // Required flags = other modifiers held alongside the captured key.
                    var flags = sanitized(event.modifierFlags)
                    flags.remove(flag)
                    capture(HotkeyConfig(keyCode: keyCode, requiredFlags: flags))
                }
            } else {
                capture(HotkeyConfig(keyCode: event.keyCode, requiredFlags: sanitized(event.modifierFlags)))
            }
            return nil // swallow while recording
        }
    }

    private func sanitized(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result = CGEventFlags()
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        return result
    }

    private func capture(_ config: HotkeyConfig) {
        hotkey = config
        onChange(config)
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
