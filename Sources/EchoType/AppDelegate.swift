import AppKit
import AVFoundation
import SwiftUI

enum AppPhase {
    case idle
    case waking
    case engaging
    case listening(handsFree: Bool)
    case pendingDoubleTap
    case transcribing
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let web = ChatGPTWebController()
    private var hotkeyMonitor: HotkeyMonitor?
    private let hud = HUDController()
    private var settingsWindow: NSWindow?
    private var accessibilityPollTimer: Timer?
    private var holdStartedAt: Date?
    private var releasedAt: Date?
    private var hotkeyHeld = false
    private var wantsHandsFree = false
    private var pendingTapTimer: Timer?
    private let tapThreshold: TimeInterval = 0.35
    private let doubleTapWindow: TimeInterval = 0.45
    private var loginMenuItem: NSMenuItem?
    private var engagementFailures = 0  // consecutive; 2+ triggers a page reload
    private var loggedIn = true {
        didSet { updateLoginMenuItem() }
    }
    private var isOnline = true {
        didSet { updateLoginMenuItem() }
    }

    private(set) var phase: AppPhase = .idle {
        didSet { updateStatusIcon() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch: AXIsProcessTrusted=\(AXIsProcessTrusted())")
        setupStatusItem()
        requestMicrophoneAccess()

        if !AXIsProcessTrusted() {
            promptForAccessibility()
        }
        // AXIsProcessTrusted can report a stale grant; poll until the tap installs.
        startHotkeyMonitorWithRetry()

        hud.onCancel = { [weak self] in self?.cancelFromHUD() }
        hud.onSubmit = { [weak self] in self?.submitFromHUD() }
        web.isBusy = { [weak self] in
            if case .idle = self?.phase ?? .idle { return false }
            return true
        }

        web.onLoginStateChange = { [weak self] loggedIn in
            DispatchQueue.main.async {
                self?.loggedIn = loggedIn
                self?.updateStatusIcon()
            }
        }
        web.onReachabilityChange = { [weak self] online in
            DispatchQueue.main.async {
                self?.isOnline = online
                self?.updateStatusIcon()
            }
        }
        web.applyPolicyAtLaunch()
        UpdateManager.shared.startAutomaticChecks()

        // ECHOTYPE_DIAG=1|flow|visible: run dictation forensics once up, then quit.
        if let diagMode = ProcessInfo.processInfo.environment["ECHOTYPE_DIAG"] {
            if diagMode == "visible" { web.showLoginWindow() }
            web.ensureReady { [weak self] result in
                DispatchQueue.main.async {
                    guard case .success = result else {
                        Log.write("diag: ensureReady failed: \(result)")
                        NSApp.terminate(nil)
                        return
                    }
                    self?.web.logWindowState()
                    if diagMode == "flow" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self?.web.driver?.startDictation { result in
                                Log.write("diag: flow startDictation -> \(result)")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    self?.web.driver?.cancelDictation { cancel in
                                        Log.write("diag: flow cancelDictation -> \(cancel)")
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                                    }
                                }
                            }
                        }
                    } else {
                        self?.web.driver?.runDiagnostics {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()

        let menu = NSMenu()
        let holdInfo = menuItem("Hold hotkey to dictate", symbol: "mic.badge.plus", action: nil)
        holdInfo.isEnabled = false
        menu.addItem(holdInfo)
        menu.addItem(.separator())
        let login = menuItem("Open ChatGPT Login…", symbol: "person.crop.circle", action: #selector(openLogin))
        loginMenuItem = login
        menu.addItem(login)
        menu.addItem(menuItem("History…", symbol: "clock.arrow.circlepath", action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(menuItem("Settings…", symbol: "gearshape", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(menuItem("Check for Updates…", symbol: "arrow.triangle.2.circlepath", action: #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit EchoType", symbol: "power", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func menuItem(_ title: String, symbol: String, action: Selector?,
                          keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private static let logoIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }()

    private func updateStatusIcon() {
        if !isOnline {
            setSymbolIcon("wifi.slash", description: "EchoType offline", tint: .systemOrange)
            return
        }
        if !loggedIn {
            setSymbolIcon("person.crop.circle.badge.exclamationmark",
                          description: "EchoType logged out", tint: .systemRed)
            return
        }
        switch phase {
        case .idle:
            if let logo = Self.logoIcon {
                statusItem.button?.image = logo
                statusItem.button?.contentTintColor = nil
                return
            }
            setSymbolIcon("mic", description: "EchoType idle", tint: nil)
        case .waking, .engaging:
            setSymbolIcon("hourglass", description: "EchoType waking", tint: nil)
        case .listening, .pendingDoubleTap:
            setSymbolIcon("mic.fill", description: "EchoType listening", tint: .systemRed)
        case .transcribing:
            setSymbolIcon("waveform", description: "EchoType transcribing", tint: nil)
        }
    }

    private func updateLoginMenuItem() {
        guard let item = loginMenuItem else { return }
        if !isOnline {
            item.title = "No internet connection — retry"
            item.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: "Offline")
        } else if loggedIn {
            item.title = "ChatGPT: Logged In ✓ (open window)"
            item.image = NSImage(systemSymbolName: "person.crop.circle.badge.checkmark",
                                 accessibilityDescription: "Logged in")
        } else {
            item.title = "Log in to ChatGPT…"
            item.image = NSImage(systemSymbolName: "person.crop.circle.badge.exclamationmark",
                                 accessibilityDescription: "Logged out")
        }
    }

    private func setSymbolIcon(_ symbolName: String, description: String, tint: NSColor?) {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = tint
    }

    // MARK: - Permissions

    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    self.showAlert(
                        title: "Microphone access needed",
                        text: "Enable EchoType in System Settings → Privacy & Security → Microphone, then relaunch."
                    )
                }
            }
        }
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startHotkeyMonitorWithRetry() {
        accessibilityPollTimer?.invalidate()
        if startHotkeyMonitorOnce() {
            Log.write("hotkey: event tap installed")
            return
        }
        Log.write("hotkey: event tap failed, polling for Accessibility grant")
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.startHotkeyMonitorOnce() else { return }
            timer.invalidate()
            self.accessibilityPollTimer = nil
            Log.write("hotkey: event tap installed after grant")
            NSSound(named: "Glass")?.play()
        }
    }

    // MARK: - Hotkey

    func startHotkeyMonitor() {
        if !startHotkeyMonitorOnce() {
            startHotkeyMonitorWithRetry()
        }
    }

    func webviewPolicyChanged() {
        web.policyChanged()
    }

    @discardableResult
    private func startHotkeyMonitorOnce() -> Bool {
        hotkeyMonitor?.stop()
        hotkeyMonitor = nil
        let monitor = HotkeyMonitor(hotkey: Settings.dictateHotkey)
        monitor.onHoldStart = { [weak self] in self?.onHotkeyDown() }
        monitor.onHoldEnd = { [weak self] in self?.onHotkeyUp() }
        guard monitor.start() else { return false }
        hotkeyMonitor = monitor
        return true
    }

    // MARK: - Dictation flow
    // HOLD: press-hold-release. HANDS-FREE: double-tap, tap again to stop.

    private func onHotkeyDown() {
        switch phase {
        case .idle:
            hotkeyHeld = true
            wantsHandsFree = false
            holdStartedAt = Date()
            releasedAt = nil
            Log.write("dictation: key down")
            startDictationSession()
        case .waking, .engaging:
            hotkeyHeld = true
            wantsHandsFree = true
            Log.write("dictation: second press while opening → hands-free")
        case .pendingDoubleTap:
            pendingTapTimer?.invalidate()
            pendingTapTimer = nil
            hotkeyHeld = true
            phase = .listening(handsFree: true)
            hud.show(state: .listening(handsFree: true))
            Log.write("dictation: hands-free engaged")
        case .listening(handsFree: true):
            Log.write("dictation: hands-free stop tap")
            finishListening()
        case .listening(handsFree: false), .transcribing:
            Log.write("dictation: key down ignored, phase busy")
        }
    }

    private func onHotkeyUp() {
        hotkeyHeld = false
        releasedAt = Date()
        let heldDuration = holdStartedAt.map { Date().timeIntervalSince($0) } ?? 0

        switch phase {
        case .listening(handsFree: false):
            if heldDuration < tapThreshold {
                enterPendingDoubleTap()
            } else {
                finishListening()
            }
        case .waking, .engaging:
            Log.write("dictation: released while \(phase)")
        default:
            break
        }
    }

    private func startDictationSession() {
        if web.webView == nil {
            phase = .waking
            hud.show(state: .starting)
        } else {
            phase = .engaging
        }
        web.ensureReady { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    guard self.hotkeyHeld || self.wantsHandsFree else {
                        Log.write("dictation: released before ready, discarded")
                        self.resetToIdle()
                        return
                    }
                    self.openMicrophone()
                case .failure(let error):
                    self.handleFailure(error)
                }
            }
        }
    }

    private func openMicrophone() {
        web.driver?.startDictation { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.engagementFailures = 0
                    NSSound(named: "Pop")?.play()
                    self.web.unmuteMicrophoneIfNeeded()
                    if self.wantsHandsFree {
                        self.phase = .listening(handsFree: true)
                        self.hud.show(state: .listening(handsFree: true))
                    } else if self.hotkeyHeld {
                        self.phase = .listening(handsFree: false)
                        self.hud.show(state: .listening(handsFree: false))
                    } else {
                        let pressLength = (self.releasedAt ?? Date()).timeIntervalSince(self.holdStartedAt ?? Date())
                        if pressLength < self.tapThreshold {
                            self.phase = .listening(handsFree: false)
                            self.hud.show(state: .listening(handsFree: false))
                            self.enterPendingDoubleTap()
                        } else {
                            self.phase = .listening(handsFree: false)
                            self.finishListening()
                        }
                    }
                case .failure(let error):
                    self.handleFailure(error)
                }
            }
        }
    }

    private func enterPendingDoubleTap() {
        phase = .pendingDoubleTap
        pendingTapTimer?.invalidate()
        pendingTapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
            guard let self, case .pendingDoubleTap = self.phase else { return }
            Log.write("dictation: single tap, cancelled")
            self.web.driver?.cancelDictation()
            self.resetToIdle()
        }
    }

    private func cancelFromHUD() {
        switch phase {
        case .listening, .pendingDoubleTap, .engaging:
            Log.write("dictation: cancelled from HUD")
            web.driver?.cancelDictation()
            resetToIdle()
        default:
            break
        }
    }

    private func submitFromHUD() {
        switch phase {
        case .listening, .pendingDoubleTap:
            Log.write("dictation: submitted from HUD")
            finishListening()
        default:
            break
        }
    }

    private func finishListening() {
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil
        phase = .transcribing
        hud.show(state: .transcribing)
        web.driver?.submitDictation { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.collectTranscript(
                        recordingDuration: self.holdStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                    )
                case .failure(let error):
                    self.handleFailure(error)
                }
            }
        }
    }

    private func collectTranscript(recordingDuration: TimeInterval = 0) {
        web.driver?.awaitTranscript(recordingDuration: recordingDuration) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let transcript):
                    self.web.driver?.clearComposer()
                    self.web.touch()
                    guard !transcript.isEmpty else {
                        Log.write("dictation: empty transcript")
                        NSSound(named: "Basso")?.play()
                        self.resetToIdle()
                        return
                    }
                    Log.write("dictation: delivering \(transcript.count) chars")
                    HistoryStore.shared.add(transcript)
                    switch Paster.deliver(transcript) {
                    case .pasted:
                        NSSound(named: "Tink")?.play()
                        self.resetToIdle()
                    case .copiedToClipboard:
                        Log.write("dictation: no editable field focused, left on clipboard")
                        NSSound(named: "Tink")?.play()
                        self.hud.show(state: .info("Copied to clipboard — press ⌘V to paste"))
                        self.phase = .idle
                    }
                case .failure(let error):
                    self.web.driver?.cancelDictation()
                    self.web.driver?.clearComposer()
                    self.handleFailure(error)
                }
            }
        }
    }

    private func handleFailure(_ error: DictationDriver.Failure) {
        let message: String
        switch error {
        case .loggedOut:
            message = "Logged out — open the EchoType menu to log in"
            loggedIn = false
        case .offline:
            message = "No internet connection — check your network"
            isOnline = false
        case .timeout:
            message = "ChatGPT didn't respond in time"
        case .buttonNotFound(let status):
            // The page wedges occasionally; only reload after two failures in a row.
            engagementFailures += 1
            if engagementFailures >= 2 {
                message = "Dictation glitched (\(status)) — reloading ChatGPT, try again"
                Log.write("dictation: \(engagementFailures) engagement failures, reloading webview to self-heal")
                engagementFailures = 0
                web.reloadInBackground()
            } else {
                message = "Dictation didn't start — try again"
            }
        case .notReady:
            message = "ChatGPT page isn't ready yet"
        case .javascript(let detail):
            message = "Page error: \(detail.prefix(60))"
        }
        Log.write("dictation: failed — \(message)")
        NSSound(named: "Basso")?.play()
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil
        wantsHandsFree = false
        hud.show(state: .error(message))
        phase = .idle
    }

    private func resetToIdle() {
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil
        wantsHandsFree = false
        phase = .idle
        hud.hide()
    }

    // MARK: - Login & Settings

    @objc private func checkForUpdates() {
        UpdateManager.shared.checkForUpdates(userInitiated: true)
    }

    @objc private func openLogin() {
        web.showLoginWindow()
    }

    private var historyWindow: NSWindow?

    @objc private func openHistory() {
        if historyWindow == nil {
            let hosting = NSHostingController(rootView: HistoryView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "EchoType History"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            historyWindow = window
        }
        historyWindow?.center()
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(appDelegate: self)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "EchoType Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Helpers

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
