import AppKit
import AVFoundation
import SwiftUI

enum AppPhase {
    case idle
    case waking                       // webview loading before the mic can open
    case engaging                     // mic opening (dictation click in flight)
    case listening(handsFree: Bool)   // hold mode, or hands-free after a double-tap
    case pendingDoubleTap             // quick tap; mic stays open briefly awaiting a 2nd tap
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
    private var wantsHandsFree = false  // 2nd press arrived while the mic was still opening
    private var pendingTapTimer: Timer?
    private let tapThreshold: TimeInterval = 0.35      // press shorter than this = a tap
    private let doubleTapWindow: TimeInterval = 0.45   // max gap between the two taps
    private var loginMenuItem: NSMenuItem?
    private var engagementFailures = 0  // consecutive; 2+ triggers a page reload
    private var loggedIn = true { // optimistic until the webview says otherwise
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
        // Always poll: AXIsProcessTrusted can report a stale grant (old signature)
        // while the event tap still fails. Keep trying until the tap installs.
        startHotkeyMonitorWithRetry()

        hud.onCancel = { [weak self] in self?.cancelFromHUD() }
        hud.onSubmit = { [weak self] in self?.submitFromHUD() }

        web.onLoginStateChange = { [weak self] loggedIn in
            DispatchQueue.main.async {
                self?.loggedIn = loggedIn
                self?.updateStatusIcon()
                if !loggedIn {
                    self?.web.showLoginWindow()
                }
            }
        }
        web.applyPolicyAtLaunch()
        UpdateManager.shared.startAutomaticChecks()

        // DIAG: ECHOTYPE_DIAG=1 runs the dictation forensics once the page is up,
        // no hotkey needed, then quits. ECHOTYPE_DIAG=visible runs it with the
        // login window shown (rendering unthrottled) to compare.
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
                        // Exercise the REAL dictation path end to end (minus speech).
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
        image.isTemplate = false // full-color logo
        return image
    }()

    private func updateStatusIcon() {
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
        if loggedIn {
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

    /// Triggers the system Accessibility prompt and opens the settings pane.
    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Tries to install the event tap; on failure retries every 2s until it
    /// succeeds (e.g. the user grants Accessibility while we wait). No relaunch needed.
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
            NSSound(named: "Glass")?.play() // audible "ready" cue
        }
    }

    // MARK: - Hotkey

    /// Called from Settings when the hotkey changes.
    func startHotkeyMonitor() {
        if !startHotkeyMonitorOnce() {
            startHotkeyMonitorWithRetry()
        }
    }

    /// Called from Settings when the webview policy changes.
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
    //
    // Two ways to dictate with the same hotkey:
    //   HOLD:       press & hold → talk → release → transcribe.
    //   HANDS-FREE: double-tap → talk freely → single tap → transcribe.
    // While transcribing, every key event is ignored — one dictation at a time.

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
            // Second press while the mic is still opening → user wants hands-free.
            hotkeyHeld = true
            wantsHandsFree = true
            Log.write("dictation: second press while opening → hands-free")
        case .pendingDoubleTap:
            // Second tap in time → hands-free mode; the mic never stopped listening.
            pendingTapTimer?.invalidate()
            pendingTapTimer = nil
            hotkeyHeld = true
            phase = .listening(handsFree: true)
            hud.show(state: .listening(handsFree: true))
            Log.write("dictation: hands-free engaged")
        case .listening(handsFree: true):
            // Tap while hands-free → stop & transcribe.
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
                // Quick tap — keep listening briefly in case a second tap follows.
                enterPendingDoubleTap()
            } else {
                finishListening()
            }
        case .waking, .engaging:
            // The ensureReady/engagement callbacks decide what to do based on
            // hotkeyHeld / wantsHandsFree / releasedAt.
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
                    // Proceed if the key is still down or a double-tap was queued;
                    // a lone short tap that ended while the page was waking is discarded.
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
                        // Released while the mic was opening.
                        let pressLength = (self.releasedAt ?? Date()).timeIntervalSince(self.holdStartedAt ?? Date())
                        if pressLength < self.tapThreshold {
                            // Was a tap — give the second tap a chance.
                            self.phase = .listening(handsFree: false)
                            self.hud.show(state: .listening(handsFree: false))
                            self.enterPendingDoubleTap()
                        } else {
                            // Was a hold that ended during engagement — wrap up immediately.
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

    /// ✕ on the HUD pill.
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

    /// ✓ on the HUD pill.
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
                    self.collectTranscript()
                case .failure(let error):
                    self.handleFailure(error)
                }
            }
        }
    }

    private func collectTranscript() {
        web.driver?.awaitTranscript { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let transcript):
                    // Always clear so nothing lingers in the ChatGPT composer.
                    self.web.driver?.clearComposer()
                    self.web.touch()
                    guard !transcript.isEmpty else {
                        Log.write("dictation: empty transcript")
                        NSSound(named: "Basso")?.play()
                        self.resetToIdle()
                        return
                    }
                    Log.write("dictation: pasting \(transcript.count) chars")
                    HistoryStore.shared.add(transcript)
                    Paster.paste(transcript)
                    NSSound(named: "Tink")?.play()
                    self.resetToIdle()
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
            message = "Logged out of ChatGPT — log in to continue"
            loggedIn = false
            web.showLoginWindow()
        case .timeout:
            message = "ChatGPT didn't respond in time"
        case .buttonNotFound(let status):
            // The page wedges occasionally (dictation click stops engaging).
            // One failure can be a hiccup — only reload after two in a row.
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
