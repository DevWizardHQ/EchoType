import AppKit
import WebKit

/// Owns the hidden WKWebView that hosts the logged-in chatgpt.com session,
/// plus the same window in "login mode" (visible) for first-run sign-in.
///
/// Lifecycle follows `Settings.webviewPolicy`:
///   - .alwaysReady: loaded at launch, never unloaded.
///   - .keepWarm:    loaded on demand, unloaded after `Settings.keepWarmDuration` idle.
final class ChatGPTWebController: NSObject {
    static let chatURL = URL(string: "https://chatgpt.com/")!
    /// Real Safari UA — avoids embedded-browser login blocks (Google SSO etc).
    private static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private(set) var webView: WKWebView?
    private(set) var driver: DictationDriver?
    private var window: NSWindow?
    private var loginWindowVisible = false
    private var idleTimer: Timer?
    private var activityToken: NSObjectProtocol?
    private var readyCallbacks: [(Result<Void, DictationDriver.Failure>) -> Void] = []
    private var loading = false

    /// Set when login state changes; AppDelegate uses it to tint the menu icon.
    var onLoginStateChange: ((Bool) -> Void)?

    // MARK: - Lifecycle

    func applyPolicyAtLaunch() {
        if Settings.webviewPolicy == .alwaysReady {
            ensureReady { _ in }
        }
    }

    /// Loads the webview (if needed) and waits until chatgpt.com is interactive.
    /// Callbacks queue up if a load is already in flight.
    func ensureReady(completion: @escaping (Result<Void, DictationDriver.Failure>) -> Void) {
        touch()
        if let driver, webView != nil, !loading {
            // Already up — verify the page is actually alive and signed in.
            driver.state { [weak self] result in
                switch result {
                case .success(let state):
                    self?.onLoginStateChange?(state.loggedIn)
                    completion(state.loggedIn ? .success(()) : .failure(.loggedOut))
                case .failure:
                    // Web process died or page wedged — reload from scratch.
                    Log.write("webview: state probe failed, reloading")
                    self?.unload()
                    self?.ensureReady(completion: completion)
                }
            }
            return
        }
        readyCallbacks.append(completion)
        guard !loading else { return }
        loading = true
        let webView = makeWebView()
        self.webView = webView
        self.driver = DictationDriver(webView: webView)
        ensureWindow(contains: webView)
        Log.write("webview: loading \(Self.chatURL)")
        webView.load(URLRequest(url: Self.chatURL))
        beginActivity()
        waitUntilInteractive(deadline: Date().addingTimeInterval(25))
    }

    /// Frees the WebContent process (~150-250 MB) while keeping cookies on disk.
    func unload() {
        Log.write("webview: unloading")
        idleTimer?.invalidate()
        idleTimer = nil
        loading = false
        flushReadyCallbacks(.failure(.notReady))
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        driver = nil
        endActivity()
    }

    /// Tears the page down and reloads it in the background — recovery path for
    /// when chatgpt.com's dictation state machine wedges (click stops engaging).
    func reloadInBackground() {
        unload()
        ensureReady { result in
            Log.write("webview: self-heal reload -> \(result)")
        }
    }

    /// Resets the keep-warm idle countdown (call on every dictation).
    func touch() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard Settings.webviewPolicy == .keepWarm, webView != nil || loading else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: Settings.keepWarmDuration, repeats: false) { [weak self] _ in
            self?.unload()
        }
    }

    /// Re-applies the current policy (call when the setting changes).
    func policyChanged() {
        switch Settings.webviewPolicy {
        case .alwaysReady:
            idleTimer?.invalidate()
            idleTimer = nil
            ensureReady { _ in }
        case .keepWarm:
            touch()
        }
    }

    // MARK: - Login window

    /// Shows the (normally invisible) webview window so the user can sign in.
    func showLoginWindow() {
        loginWindowVisible = true
        ensureReady { _ in } // make sure there is a page to log into
        guard let window else { return }
        window.alphaValue = 1
        window.level = .normal
        window.ignoresMouseEvents = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideLoginWindow() {
        loginWindowVisible = false
        guard let window else { return }
        applyHiddenWindowMode(window)
    }

    /// "Hidden" = visually imperceptible but still visible to WebKit: alpha 0
    /// or an occluded window makes WebKit treat the page as hidden, which
    /// blocks chatgpt.com's mic capture. Floating + 1% alpha keeps capture alive.
    private func applyHiddenWindowMode(_ window: NSWindow) {
        window.alphaValue = 0.01
        window.level = .floating
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
    }

    /// WebKit mutes a webview's capture when it judges the view non-visible;
    /// flip it back while a dictation is running.
    func unmuteMicrophoneIfNeeded() {
        guard let webView else { return }
        if webView.microphoneCaptureState == .muted {
            Log.write("webview: mic capture was muted — forcing active")
            webView.setMicrophoneCaptureState(.active)
        }
    }

    /// DIAG: how AppKit/WindowServer judge the hidden window.
    func logWindowState() {
        guard let window else { Log.write("diag: no window"); return }
        Log.write("diag: window isVisible=\(window.isVisible) occlusionVisible=\(window.occlusionState.contains(.visible)) alpha=\(window.alphaValue) frame=\(window.frame) screen=\(NSScreen.main?.frame ?? .zero)")
    }

    // MARK: - Internals

    /// chatgpt.com refuses to start dictation when the page reports itself hidden
    /// or unfocused (our window is invisible and never key), so pin the Page
    /// Visibility + focus APIs to "visible & focused". Also hooks getUserMedia
    /// and console errors EARLY — before the site's bundle captures references —
    /// so failures are diagnosable from the app log.
    private static let visibilitySpoofScript = """
    (function () {
      try {
        Object.defineProperty(Document.prototype, 'visibilityState', { get: function () { return 'visible'; } });
        Object.defineProperty(Document.prototype, 'hidden', { get: function () { return false; } });
        Document.prototype.hasFocus = function () { return true; };
        document.addEventListener('visibilitychange', function (e) { e.stopImmediatePropagation(); }, true);
        window.addEventListener('pagehide', function (e) { e.stopImmediatePropagation(); }, true);
        window.addEventListener('blur', function (e) { e.stopImmediatePropagation(); }, true);
      } catch (e) {}
      try {
        // WebKit freezes the rendering pipeline (rAF never fires) when it judges
        // the window invisible — chatgpt.com's dictation flow awaits an animation
        // frame and silently stalls. Race every rAF against a 33 ms timer so
        // callbacks always run; real frames win when the window is visible.
        if (!window.__etRAF) {
          window.__etRAF = true;
          const nativeRAF = window.requestAnimationFrame.bind(window);
          const nativeCAF = window.cancelAnimationFrame.bind(window);
          let nextId = 1;
          const pending = new Map();
          window.requestAnimationFrame = function (cb) {
            const id = nextId++;
            const fire = function (ts) {
              const p = pending.get(id);
              if (!p) return;
              pending.delete(id);
              nativeCAF(p.raf);
              clearTimeout(p.timer);
              try { cb(ts); } catch (e) { setTimeout(function () { throw e; }, 0); }
            };
            const raf = nativeRAF(fire);
            const timer = setTimeout(function () { fire(performance.now()); }, 33);
            pending.set(id, { raf: raf, timer: timer });
            return id;
          };
          window.cancelAnimationFrame = function (id) {
            const p = pending.get(id);
            if (!p) return;
            pending.delete(id);
            nativeCAF(p.raf);
            clearTimeout(p.timer);
          };
        }
      } catch (e) {}
      try {
        if (navigator.mediaDevices && !navigator.mediaDevices.__etWrapped) {
          const orig = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
          navigator.mediaDevices.getUserMedia = function (c) {
            window.__etGUM = 'requested';
            return orig(c).then(function (s) { window.__etGUM = 'ok'; return s; })
                          .catch(function (e) { window.__etGUM = 'err:' + e.name + ':' + e.message; throw e; });
          };
          navigator.mediaDevices.__etWrapped = true;
        }
      } catch (e) {}
      try {
        if (!window.__etLogs) {
          window.__etLogs = [];
          const push = function (kind, args) {
            try {
              const msg = Array.prototype.map.call(args, function (a) {
                return (a && a.stack) ? a.stack.split('\\n')[0] : String(a);
              }).join(' ');
              window.__etLogs.push(kind + ': ' + msg.slice(0, 200));
              if (window.__etLogs.length > 20) window.__etLogs.shift();
            } catch (e) {}
          };
          const origError = console.error.bind(console);
          console.error = function () { push('error', arguments); origError.apply(null, arguments); };
          const origWarn = console.warn.bind(console);
          console.warn = function () { push('warn', arguments); origWarn.apply(null, arguments); };
          window.addEventListener('unhandledrejection', function (e) {
            push('rejection', [e.reason && (e.reason.message || e.reason)]);
          });
          window.addEventListener('error', function (e) { push('jserror', [e.message]); });
        }
      } catch (e) {}
    })();
    """

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent cookies → login survives restarts
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.visibilitySpoofScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: DictationDriver.userScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        config.userContentController = controller

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        webView.customUserAgent = Self.safariUA
        webView.uiDelegate = self
        webView.navigationDelegate = self
        return webView
    }

    /// One window serves both modes: alpha 0 + mouse-transparent when hidden,
    /// normal when shown for login. Staying ordered on screen (rather than
    /// orderOut) keeps WebKit from throttling timers and media capture.
    private func ensureWindow(contains webView: WKWebView) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "EchoType — ChatGPT Login"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            self.window = window
        }
        window?.contentView = webView
        // A freshly created window starts at alpha 1 but is NOT ordered on
        // screen — and an unordered window freezes WebKit's render pipeline,
        // which silently kills chatgpt.com's dictation flow. Always order it,
        // hidden unless the login window is currently being shown.
        if let window, !loginWindowVisible {
            applyHiddenWindowMode(window)
        }
    }

    /// Polls the page until the composer renders (SPA hydration takes a beat
    /// after didFinish), then drains the ready queue.
    private func waitUntilInteractive(deadline: Date) {
        guard loading, let driver else { return }
        driver.state { [weak self] result in
            guard let self, self.loading else { return }
            switch result {
            case .success(let state) where state.loggedIn:
                Log.write("webview: ready, logged in")
                self.loading = false
                self.onLoginStateChange?(true)
                self.flushReadyCallbacks(.success(()))
            case .success:
                // Page is up but logged out (or composer not yet hydrated).
                if Date() > deadline {
                    Log.write("webview: ready but logged OUT")
                    self.loading = false
                    self.onLoginStateChange?(false)
                    self.flushReadyCallbacks(.failure(.loggedOut))
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.waitUntilInteractive(deadline: deadline)
                    }
                }
            case .failure(let error):
                if Date() > deadline {
                    Log.write("webview: load timeout (\(error))")
                    self.loading = false
                    self.flushReadyCallbacks(.failure(.timeout))
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.waitUntilInteractive(deadline: deadline)
                    }
                }
            }
        }
    }

    private func flushReadyCallbacks(_ result: Result<Void, DictationDriver.Failure>) {
        let callbacks = readyCallbacks
        readyCallbacks = []
        callbacks.forEach { $0(result) }
    }

    /// Keeps the app (and the webview's media capture) out of App Nap while loaded.
    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "EchoType dictation session"
        )
    }

    private func endActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
}

// MARK: - WKUIDelegate

extension ChatGPTWebController: WKUIDelegate {
    /// Auto-grant the page's microphone request — the OS-level mic permission
    /// is still enforced against the app itself.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let isChatGPT = origin.host.hasSuffix("chatgpt.com") || origin.host.hasSuffix("openai.com")
        decisionHandler(isChatGPT && (type == .microphone || type == .cameraAndMicrophone) ? .grant : .deny)
    }
}

// MARK: - WKNavigationDelegate

extension ChatGPTWebController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.write("webview: didFinish \(webView.url?.absoluteString ?? "?")")
        // Landing back on chatgpt.com (e.g. after the user signs in via the login
        // window) — re-probe so the menu icon updates and the window auto-hides.
        guard webView.url?.host?.hasSuffix("chatgpt.com") == true, !loading else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let driver = self.driver else { return }
            driver.state { result in
                guard case .success(let state) = result else { return }
                DispatchQueue.main.async {
                    Log.write("webview: post-navigation probe, loggedIn=\(state.loggedIn)")
                    self.onLoginStateChange?(state.loggedIn)
                    if state.loggedIn, self.window?.alphaValue == 1 {
                        self.hideLoginWindow()
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("webview: didFail \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.write("webview: web content process terminated")
        unload()
    }
}

// MARK: - NSWindowDelegate

extension ChatGPTWebController: NSWindowDelegate {
    /// Closing the login window hides it back into invisible mode instead of
    /// destroying the session.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideLoginWindow()
        return false
    }
}
