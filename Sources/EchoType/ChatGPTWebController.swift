import AppKit
import Network
import WebKit

/// Owns the hidden WKWebView hosting chatgpt.com; same window shown for login.
final class ChatGPTWebController: NSObject {
    static let chatURL = URL(string: "https://chatgpt.com/")!
    /// Real Safari UA — avoids embedded-browser login blocks (Google SSO etc).
    private static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private static let offlineHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      html,body{height:100%;margin:0}
      body{display:flex;align-items:center;justify-content:center;
        font:15px -apple-system,system-ui,sans-serif;color:#e5e5e5;background:#1e1e1e}
      .card{text-align:center;max-width:340px;padding:0 24px}
      .icon{font-size:44px;margin-bottom:12px}
      h1{font-size:19px;font-weight:600;margin:0 0 8px}
      p{color:#a0a0a0;line-height:1.5;margin:0 0 24px}
      button{font:inherit;font-weight:600;color:#fff;background:#10a37f;border:0;
        border-radius:8px;padding:10px 22px;cursor:pointer}
      button:hover{background:#0e8f6f}
    </style></head><body>
      <div class="card">
        <div class="icon">📡</div>
        <h1>No internet connection</h1>
        <p>EchoType can't reach ChatGPT. Check your network, then try again.</p>
        <button onclick="window.webkit.messageHandlers.retry.postMessage('retry')">Retry</button>
      </div>
    </body></html>
    """

    private(set) var webView: WKWebView?
    private(set) var driver: DictationDriver?
    private var window: NSWindow?
    private var loginWindowVisible = false
    private var idleTimer: Timer?
    private var activityToken: NSObjectProtocol?
    private var readyCallbacks: [(Result<Void, DictationDriver.Failure>) -> Void] = []
    private var loading = false

    // MARK: - Reachability
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.echotype.reachability")
    private(set) var isOnline = true
    private var showingOfflinePage = false

    var onLoginStateChange: ((Bool) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?

    override init() {
        super.init()
        // Screen changes can strand the parked window fully offscreen (freezes WebKit) — re-park.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window, !self.loginWindowVisible else { return }
            self.applyHiddenWindowMode(window)
        }
        startReachabilityMonitor()
    }

    // MARK: - Reachability

    private func startReachabilityMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = online
                if wasOnline != online {
                    Log.write("reachability: \(online ? "online" : "offline")")
                    self.onReachabilityChange?(online)
                }
                if online, !wasOnline {
                    self.recoverFromOffline()
                }
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func recoverFromOffline() {
        if showingOfflinePage {
            retryLoad()
        } else if Settings.webviewPolicy == .alwaysReady, webView == nil, !loading {
            ensureReady { _ in }
        }
    }

    private func retryLoad() {
        guard let webView else { showLoginWindow(); return }
        showingOfflinePage = false
        if driver == nil { driver = DictationDriver(webView: webView) }
        loading = true
        Log.write("webview: retrying \(Self.chatURL)")
        webView.load(URLRequest(url: Self.chatURL))
        beginActivity()
        waitUntilInteractive(deadline: Date().addingTimeInterval(25))
    }

    var isBusy: (() -> Bool)?

    // MARK: - Lifecycle

    func applyPolicyAtLaunch() {
        if Settings.webviewPolicy == .alwaysReady {
            ensureReady { _ in }
        }
    }

    func ensureReady(completion: @escaping (Result<Void, DictationDriver.Failure>) -> Void) {
        touch()
        // Offline: fail fast instead of loading a blank frozen page for 25s.
        if !isOnline, webView == nil {
            Log.write("webview: ensureReady while offline — failing fast")
            completion(.failure(.offline))
            return
        }
        if let driver, webView != nil, !loading {
            driver.state { [weak self] result in
                switch result {
                case .success(let state):
                    self?.onLoginStateChange?(state.loggedIn)
                    completion(state.loggedIn ? .success(()) : .failure(.loggedOut))
                case .failure:
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

    /// Frees the WebContent process while keeping cookies on disk.
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

    /// Self-heal path for when chatgpt.com's dictation state machine wedges.
    func reloadInBackground() {
        unload()
        ensureReady { result in
            Log.write("webview: self-heal reload -> \(result)")
        }
    }

    func touch() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard Settings.webviewPolicy == .keepWarm, webView != nil || loading else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: Settings.keepWarmDuration, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.isBusy?() == true {
                self.touch()
            } else {
                self.unload()
            }
        }
    }

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

    /// Menu-driven only; never auto-called, so logged-out/offline can't loop it open.
    func showLoginWindow() {
        loginWindowVisible = true
        if !isOnline {
            ensureWebViewForLogin()
            presentOfflinePage()
        } else {
            showingOfflinePage = false
            ensureReady { _ in }
        }
        guard let window else { return }
        showLoginChrome(window)
    }

    private func showLoginChrome(_ window: NSWindow) {
        window.alphaValue = 1
        window.hasShadow = true
        window.level = .normal
        window.ignoresMouseEvents = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Builds the webview + window without a network load (to host the offline page).
    private func ensureWebViewForLogin() {
        if webView == nil {
            let webView = makeWebView()
            self.webView = webView
            self.driver = DictationDriver(webView: webView)
            ensureWindow(contains: webView)
        }
    }

    private func presentOfflinePage() {
        guard let webView else { return }
        showingOfflinePage = true
        webView.stopLoading()
        webView.loadHTMLString(Self.offlineHTML, baseURL: nil)
    }

    func hideLoginWindow() {
        loginWindowVisible = false
        guard let window else { return }
        applyHiddenWindowMode(window)
    }

    /// Imperceptible but still visible to WebKit — alpha 0 / occluded kills mic capture.
    private func applyHiddenWindowMode(_ window: NSWindow) {
        window.alphaValue = 0.01
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        // Park nearly offscreen; a 2-pt sliver must stay on-screen or WebKit freezes.
        if let screen = NSScreen.main {
            let f = screen.frame
            window.setFrameOrigin(NSPoint(x: f.maxX - 2, y: f.minY + 40 - window.frame.height))
        }
        window.orderFrontRegardless()
    }

    /// WebKit mutes capture when it judges the view non-visible; force it active.
    func unmuteMicrophoneIfNeeded() {
        guard let webView else { return }
        if webView.microphoneCaptureState == .muted {
            Log.write("webview: mic capture was muted — forcing active")
            webView.setMicrophoneCaptureState(.active)
        }
    }

    func logWindowState() {
        guard let window else { Log.write("diag: no window"); return }
        Log.write("diag: window isVisible=\(window.isVisible) occlusionVisible=\(window.occlusionState.contains(.visible)) alpha=\(window.alphaValue) frame=\(window.frame) screen=\(NSScreen.main?.frame ?? .zero)")
    }

    // MARK: - Internals

    /// Pins Page Visibility + focus to visible/focused; hooks getUserMedia + console early.
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
        config.websiteDataStore = .default()
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
        controller.add(self, name: "retry")
        config.userContentController = controller

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        webView.customUserAgent = Self.safariUA
        webView.uiDelegate = self
        webView.navigationDelegate = self
        return webView
    }

    /// One window, two modes: hidden (alpha 0) or visible for login. Stays ordered
    /// on screen (never orderOut) so WebKit keeps timers and media capture alive.
    private func ensureWindow(contains webView: WKWebView) {
        if window == nil {
            let window = OffscreenCapableWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "EchoType — ChatGPT Login"
            window.isReleasedWhenClosed = false
            window.delegate = self
            // .canJoinAllSpaces: else switching Space occludes the window and freezes WebKit.
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            self.window = window
        }
        window?.contentView = webView
        // Must be ordered on-screen (hidden) or WebKit's render pipeline freezes.
        if let window, !loginWindowVisible {
            applyHiddenWindowMode(window)
        }
    }

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

    /// Keeps the app (and its media capture) out of App Nap while loaded.
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

/// Skips AppKit's on-screen constraint so hidden mode can park nearly offscreen.
private final class OffscreenCapableWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - WKUIDelegate

extension ChatGPTWebController: WKUIDelegate {
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

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("webview: didFailProvisionalNavigation \(error.localizedDescription)")
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("webview: didFail \(error.localizedDescription)")
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: Error) {
        guard isNetworkError(error) else { return }
        loading = false
        flushReadyCallbacks(.failure(.offline))
        if loginWindowVisible {
            presentOfflinePage()
        }
    }

    private func isNetworkError(_ error: Error) -> Bool {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return false }
        switch e.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed, NSURLErrorTimedOut,
             NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
            return true
        default:
            return false
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.write("webview: web content process terminated")
        unload()
    }
}

// MARK: - WKScriptMessageHandler

extension ChatGPTWebController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "retry" else { return }
        Log.write("webview: retry from offline page")
        retryLoad()
    }
}

// MARK: - NSWindowDelegate

extension ChatGPTWebController: NSWindowDelegate {
    /// Closing the login window hides it instead of destroying the session.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideLoginWindow()
        return false
    }
}
