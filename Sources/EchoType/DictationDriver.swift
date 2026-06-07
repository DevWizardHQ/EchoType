import Foundation
import WebKit

/// JS bridge to chatgpt.com's dictation UI inside the hidden webview.
/// All DOM specifics come from `Selectors`; this file owns the JS plumbing
/// and the Swift-side async wrappers.
final class DictationDriver {
    enum Failure: Error {
        case notReady
        case loggedOut
        case buttonNotFound(String)
        case timeout
        case javascript(String)
    }

    struct PageState {
        let loggedIn: Bool
        let dictating: Bool
        let composerText: String
        let gum: String            // last getUserMedia outcome: none | requested | ok | err:<name>:<msg>
        let userActivation: String // none | active | had | unsupported
        let lastClick: String      // last click the page received, for click-synthesis debugging
    }

    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// The injected helper namespace. Added as a WKUserScript at document end,
    /// and re-asserted before each call (SPA navigations keep window state, but
    /// this makes the driver immune to hard reloads).
    static var userScript: String {
        """
        (function () {
          if (window.__echotype) return;
          const S = \(Selectors.js);
          const E = {};
          // Record getUserMedia outcomes so mic failures are diagnosable from Swift.
          if (navigator.mediaDevices && !navigator.mediaDevices.__etWrapped) {
            const orig = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
            navigator.mediaDevices.getUserMedia = (c) => {
              window.__etGUM = 'requested';
              return orig(c).then(s => { window.__etGUM = 'ok'; return s; })
                            .catch(e => { window.__etGUM = 'err:' + e.name + ':' + e.message; throw e; });
            };
            navigator.mediaDevices.__etWrapped = true;
          }
          // Record the last click the page actually received (position, trust,
          // target) — tells us whether native click synthesis lands correctly.
          if (!window.__etClickHooked) {
            document.addEventListener('click', (e) => {
              const btn = e.target && e.target.closest ? e.target.closest('button') : null;
              window.__etLastClick = {
                x: Math.round(e.clientX), y: Math.round(e.clientY),
                trusted: e.isTrusted,
                target: btn ? (btn.getAttribute('aria-label') || btn.getAttribute('data-testid') || 'button') : (e.target.tagName || '?')
              };
            }, true);
            window.__etClickHooked = true;
          }
          const buttons = () => [...document.querySelectorAll('button')];
          const label = (b) => (b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('data-testid') || '');
          const matches = (b, pattern) => new RegExp(pattern, 'i').test(label(b));
          const forbidden = (b) => S.neverClick.some(p => matches(b, p));
          E.findButton = (patterns) => {
            for (const p of patterns) {
              const hit = buttons().find(b => matches(b, p) && !forbidden(b));
              if (hit) return hit;
            }
            return null;
          };
          E.composer = () => {
            for (const sel of S.composer) {
              const el = document.querySelector(sel);
              if (el) return el;
            }
            return null;
          };
          // The composer leaves the DOM while dictation is active, so "logged in"
          // must accept the dictating state too.
          E.loggedIn = () => !document.querySelector(S.loggedOutMarker) && (!!E.composer() || E.isDictating());
          E.composerText = () => {
            const c = E.composer();
            return c ? c.innerText.replace(/\\u200b/g, '').trim() : '';
          };
          E.clearComposer = () => {
            const c = E.composer();
            if (!c) return 'no-composer';
            c.focus();
            const sel = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(c);
            sel.removeAllRanges();
            sel.addRange(range);
            document.execCommand('delete');
            return 'ok';
          };
          E.isDictating = () => !!(E.findButton(S.submit) || E.findButton(S.cancel));
          E.start = () => {
            if (!E.loggedIn()) return 'logged-out';
            if (E.isDictating()) return 'ok';
            const b = E.findButton(S.start);
            if (!b) return 'no-start-button';
            b.click();
            return 'ok';
          };
          E.submit = () => {
            const b = E.findButton(S.submit);
            if (!b) return 'no-submit-button';
            b.click();
            return 'ok';
          };
          E.cancel = () => {
            const b = E.findButton(S.cancel);
            if (!b) return 'no-cancel-button';
            b.click();
            return 'ok';
          };
          E.state = () => JSON.stringify({
            loggedIn: E.loggedIn(),
            dictating: E.isDictating(),
            text: E.composerText(),
            gum: window.__etGUM || 'none',
            ua: navigator.userActivation
              ? (navigator.userActivation.isActive ? 'active' : (navigator.userActivation.hasBeenActive ? 'had' : 'none'))
              : 'unsupported',
            lastClick: window.__etLastClick || null
          });
          E.dump = () => JSON.stringify(
            buttons().map(b => ({ a: b.getAttribute('aria-label'), t: b.getAttribute('data-testid') }))
                     .filter(x => x.a || x.t)
          );
          // Full synthetic pointer/mouse sequence dispatched straight at the button.
          // Untrusted, but React handlers don't check isTrusted — they only need
          // the user-activation a preceding native click already granted.
          E.jsClick = (kind) => {
            const b = E.findButton(S[kind]);
            if (!b) return 'null';
            const r = b.getBoundingClientRect();
            const opts = {
              bubbles: true, cancelable: true, composed: true, view: window,
              clientX: r.x + r.width / 2, clientY: r.y + r.height / 2,
              button: 0, buttons: 1, pointerId: 1, isPrimary: true, pointerType: 'mouse'
            };
            ['pointerover', 'pointerenter', 'pointermove'].forEach(t => b.dispatchEvent(new PointerEvent(t, opts)));
            b.dispatchEvent(new PointerEvent('pointerdown', opts));
            b.dispatchEvent(new MouseEvent('mousedown', opts));
            b.focus();
            b.dispatchEvent(new PointerEvent('pointerup', opts));
            b.dispatchEvent(new MouseEvent('mouseup', opts));
            b.dispatchEvent(new MouseEvent('click', opts));
            return 'ok';
          };
          // Failure forensics: can WE open the mic? Any dialog swallowing the flow?
          E.testMic = () => navigator.mediaDevices.getUserMedia({ audio: true })
            .then(s => { s.getTracks().forEach(t => t.stop()); return 'mic-ok'; })
            .catch(e => 'mic-err:' + e.name + ':' + e.message);
          E.dialogs = () => JSON.stringify(
            [...document.querySelectorAll('[role="dialog"], dialog')].map(d => (d.textContent || '').trim().slice(0, 150))
          );
          // DIAG: button forensics — disabled state, React props, geometry.
          E.btnInfo = (kind) => {
            const b = E.findButton(S[kind]);
            if (!b) return 'null';
            const propsKey = Object.keys(b).find(k => k.startsWith('__reactProps'));
            const props = propsKey ? b[propsKey] : null;
            const r = b.getBoundingClientRect();
            return JSON.stringify({
              disabled: b.disabled, ariaDisabled: b.getAttribute('aria-disabled'),
              rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) },
              propsKeys: props ? Object.keys(props) : null,
              html: b.outerHTML.slice(0, 250)
            });
          };
          // DIAG: bypass the DOM event system — invoke the React fiber handlers directly.
          E.reactClick = (kind) => {
            const b = E.findButton(S[kind]);
            if (!b) return 'null';
            const propsKey = Object.keys(b).find(k => k.startsWith('__reactProps'));
            if (!propsKey) return 'no-props';
            const props = b[propsKey];
            const mk = (type) => {
              const native = new MouseEvent(type, { bubbles: true, cancelable: true, view: window });
              return {
                type, target: b, currentTarget: b, nativeEvent: native, isTrusted: false,
                bubbles: true, cancelable: true, defaultPrevented: false, eventPhase: 2,
                preventDefault() {}, stopPropagation() {}, isDefaultPrevented: () => false,
                isPropagationStopped: () => false, persist() {}, timeStamp: native.timeStamp,
                button: 0, buttons: 1, clientX: 0, clientY: 0, pointerId: 1, pointerType: 'mouse'
              };
            };
            const fired = [];
            try {
              for (const k of ['onPointerDown', 'onMouseDown', 'onPointerUp', 'onMouseUp', 'onClick']) {
                if (typeof props[k] === 'function') { props[k](mk(k.slice(2).toLowerCase())); fired.push(k); }
              }
            } catch (e) { return 'threw:' + (e && e.message); }
            return fired.length ? 'invoked:' + fired.join('+') : 'no-handlers:' + Object.keys(props).join(',');
          };
          // DIAG: media capability snapshot.
          E.mediaSupport = () => JSON.stringify({
            mediaRecorder: typeof MediaRecorder !== 'undefined',
            webm: typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported('audio/webm'),
            mp4: typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported('audio/mp4'),
            audioContext: typeof AudioContext !== 'undefined',
            audioWorklet: typeof AudioContext !== 'undefined' && 'audioWorklet' in AudioContext.prototype,
            wasm: typeof WebAssembly !== 'undefined',
            sab: typeof SharedArrayBuffer !== 'undefined',
            crossOriginIsolated: !!window.crossOriginIsolated,
            visibility: document.visibilityState, hasFocus: document.hasFocus()
          });
          // DIAG: permission + device probes — silent bail candidates in the handler.
          E.permMic = () => navigator.permissions
            ? navigator.permissions.query({ name: 'microphone' }).then(r => 'perm:' + r.state)
                .catch(e => 'perm-err:' + e.name + ':' + e.message)
            : Promise.resolve('no-permissions-api');
          E.devices = () => navigator.mediaDevices.enumerateDevices()
            .then(ds => JSON.stringify(ds.map(d => d.kind + ':' + (d.label || '(no label)') + ':' + (d.deviceId ? 'id' : 'no-id'))))
            .catch(e => 'devices-err:' + e.name);
          // DIAG: record all network activity (fetch/XHR/WebSocket) around the click.
          E.netHook = () => {
            if (window.__etNet) return 'already';
            window.__etNet = [];
            const push = (s) => { window.__etNet.push(String(s).slice(0, 200)); if (window.__etNet.length > 80) window.__etNet.shift(); };
            const of = window.fetch;
            window.fetch = function () {
              const url = String((arguments[0] && arguments[0].url) || arguments[0]);
              return of.apply(this, arguments).then(
                r => { push(r.status + ' ' + url); return r; },
                e => { push('ERR ' + url + ' ' + (e && e.message)); throw e; });
            };
            const oOpen = XMLHttpRequest.prototype.open, oSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function (m, u) { this.__etURL = u; return oOpen.apply(this, arguments); };
            XMLHttpRequest.prototype.send = function () {
              this.addEventListener('loadend', () => push('xhr ' + this.status + ' ' + this.__etURL));
              return oSend.apply(this, arguments);
            };
            const OW = window.WebSocket;
            const WS = function (u, p) { push('ws ' + u); return p !== undefined ? new OW(u, p) : new OW(u); };
            WS.prototype = OW.prototype;
            ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(k => WS[k] = OW[k]);
            window.WebSocket = WS;
            return 'hooked';
          };
          E.netLog = () => JSON.stringify(window.__etNet || []);
          // DIAG: the dictation button's actual onClick source — names the bail conditions.
          E.handlerSrc = (kind) => {
            const b = E.findButton(S[kind]);
            if (!b) return 'null';
            const propsKey = Object.keys(b).find(k => k.startsWith('__reactProps'));
            if (!propsKey) return 'no-props';
            const f = b[propsKey].onClick;
            return f ? f.toString().slice(0, 2800) : 'no-onclick';
          };
          // DIAG: locate the dictation-start code in the site bundle and dump the
          // context around it — names the silent-bail gate.
          E.findBundle = async () => {
            const urls = [...new Set([
              ...[...document.scripts].map(s => s.src),
              ...performance.getEntriesByType('resource').filter(r => r.name.includes('.js')).map(r => r.name)
            ])].filter(Boolean);
            for (const u of urls) {
              try {
                const t = await fetch(u).then(r => r.text());
                const i = t.indexOf('Clicked to start dictation');
                if (i >= 0) return JSON.stringify({ url: u, ctx: t.slice(Math.max(0, i - 2600), i + 400) });
              } catch (e) {}
            }
            return 'not-found in ' + urls.length + ' scripts';
          };
          // DIAG: generic bundle search — dump context around a needle.
          E.searchBundle = async (needle) => {
            const urls = [...new Set([
              ...[...document.scripts].map(s => s.src),
              ...performance.getEntriesByType('resource').filter(r => r.name.includes('.js')).map(r => r.name)
            ])].filter(Boolean);
            const hits = [];
            for (const u of urls) {
              try {
                const t = await fetch(u).then(r => r.text());
                let i = -1;
                while ((i = t.indexOf(needle, i + 1)) >= 0 && hits.length < 3) {
                  hits.push(t.slice(Math.max(0, i - 1200), i + 1400));
                }
                if (hits.length >= 3) break;
              } catch (e) {}
            }
            return hits.length ? JSON.stringify(hits) : 'not-found';
          };
          // DIAG: does AudioContext.resume() work, or hang while the page is "invisible"?
          E.audioTest = async () => {
            const c = new AudioContext();
            const t0 = performance.now();
            const p = c.resume().then(() => 'resumed:' + c.state);
            const r = await Promise.race([p, new Promise(res => setTimeout(() => res('resume-HANG state:' + c.state), 3000))]);
            try { c.close(); } catch (e) {}
            return r + ' in ' + Math.round(performance.now() - t0) + 'ms';
          };
          // DIAG: does requestAnimationFrame run? Hidden windows can throttle it to 0.
          E.rafTest = () => new Promise(res => {
            let n = 0;
            const t0 = performance.now();
            const tick = () => { n++; (performance.now() - t0 < 1000) ? requestAnimationFrame(tick) : res('raf-frames-in-1s:' + n); };
            requestAnimationFrame(tick);
            setTimeout(() => res('raf-frames-in-1s:' + n + ' (timeout)'), 2000);
          });
          // DIAG: raw dialog markup, to identify silent/empty modals.
          E.dialogHTML = () => JSON.stringify(
            [...document.querySelectorAll('[role="dialog"], dialog')].map(d => d.outerHTML.slice(0, 400))
          );
          // Viewport-relative center of a dictation button, for native click synthesis.
          E.centerOf = (kind) => {
            const b = E.findButton(S[kind]);
            if (!b) return 'null';
            b.scrollIntoView({ block: 'nearest' });
            const r = b.getBoundingClientRect();
            return JSON.stringify({ x: r.x + r.width / 2, y: r.y + r.height / 2 });
          };
          window.__echotype = E;
        })();
        """
    }

    // MARK: - Native click synthesis
    //
    // WebKit only grants user activation (required for mic capture / AudioContext)
    // to REAL input events — JS element.click() silently leaves the page without
    // activation and ChatGPT's dictation never starts. So buttons are pressed by
    // sending genuine NSEvents into the (invisible) window at the button's location.

    private func nativeClick(kind: String, completion: @escaping (Result<Void, Failure>) -> Void) {
        call("window.__echotype.centerOf('\(kind)')") { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success("null"):
                self?.logButtonDump(context: "no-\(kind)-button")
                completion(.failure(.buttonNotFound("no-\(kind)-button")))
            case .success(let json):
                guard let self, let webView = self.webView,
                      let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let x = obj["x"] as? Double, let y = obj["y"] as? Double else {
                    completion(.failure(.javascript("bad centerOf JSON")))
                    return
                }
                DispatchQueue.main.async {
                    self.sendClick(to: webView, cssPoint: CGPoint(x: x, y: y))
                    completion(.success(()))
                }
            }
        }
    }

    private func sendClick(to webView: WKWebView, cssPoint: CGPoint) {
        guard let window = webView.window else { return }
        // CSS viewport coords are top-left based; convert through the view so
        // flippedness is handled for us.
        let viewPoint = webView.isFlipped
            ? cssPoint
            : CGPoint(x: cssPoint.x, y: webView.bounds.height - cssPoint.y)
        let windowPoint = webView.convert(viewPoint, to: nil)

        func mouseEvent(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        // Deliver straight to the web view's responder methods: window.sendEvent
        // on a non-key window treats the click as "first mouse" and swallows it
        // before the DOM ever sees it.
        if let down = mouseEvent(.leftMouseDown) { webView.mouseDown(with: down) }
        if let up = mouseEvent(.leftMouseUp) { webView.mouseUp(with: up) }
        Log.write("driver: native click at css(\(Int(cssPoint.x)),\(Int(cssPoint.y))) window(\(Int(windowPoint.x)),\(Int(windowPoint.y)))")
    }

    // MARK: - Swift wrappers

    private func call(_ expression: String, completion: @escaping (Result<String, Failure>) -> Void) {
        guard let webView else {
            completion(.failure(.notReady))
            return
        }
        // Re-assert the namespace, then call. Cheap no-op when already present.
        let js = Self.userScript + "\nreturn String(\(expression));"
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                completion(.success(value as? String ?? ""))
            case .failure(let error):
                completion(.failure(.javascript(error.localizedDescription)))
            }
        }
    }

    func state(completion: @escaping (Result<PageState, Failure>) -> Void) {
        call("window.__echotype.state()") { result in
            switch result {
            case .success(let json):
                guard let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(.javascript("bad state JSON: \(json.prefix(200))")))
                    return
                }
                var click = "none"
                if let lastClick = obj["lastClick"] as? [String: Any] {
                    click = "(\(lastClick["x"] ?? "?"),\(lastClick["y"] ?? "?")) trusted=\(lastClick["trusted"] ?? "?") target=\(lastClick["target"] ?? "?")"
                }
                completion(.success(PageState(
                    loggedIn: obj["loggedIn"] as? Bool ?? false,
                    dictating: obj["dictating"] as? Bool ?? false,
                    composerText: obj["text"] as? String ?? "",
                    gum: obj["gum"] as? String ?? "none",
                    userActivation: obj["ua"] as? String ?? "?",
                    lastClick: click
                )))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func startDictation(completion: @escaping (Result<Void, Failure>) -> Void) {
        state { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let state):
                guard state.loggedIn else {
                    completion(.failure(.loggedOut))
                    return
                }
                if state.dictating {
                    completion(.success(()))
                    return
                }
                // Clear leftovers so the composer holds exactly this dictation's text.
                self.call("window.__echotype.clearComposer()") { _ in
                    // Native click first: grants WebKit user activation (required
                    // for mic/AudioContext). If the React handler misses it, follow
                    // up with a synthetic pointer sequence that React reliably sees —
                    // the activation from the native click is still fresh.
                    self.nativeClick(kind: "start") { result in
                        switch result {
                        case .failure(let error):
                            completion(.failure(error))
                        case .success:
                            self.awaitEngagement(deadline: Date().addingTimeInterval(1.2), forensics: false) { firstTry in
                                if case .success = firstTry {
                                    completion(.success(()))
                                    return
                                }
                                Log.write("driver: native click didn't engage, retrying via JS pointer events")
                                self.call("window.__echotype.jsClick('start')") { _ in
                                    self.awaitEngagement(deadline: Date().addingTimeInterval(3), completion: completion)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func awaitEngagement(deadline: Date, forensics: Bool = true,
                                 completion: @escaping (Result<Void, Failure>) -> Void) {
        state { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let state):
                if state.dictating {
                    completion(.success(()))
                } else if Date() > deadline {
                    if forensics {
                        Log.write("driver: dictation never engaged (gum=\(state.gum) ua=\(state.userActivation) lastClick=\(state.lastClick))")
                        self?.call("JSON.stringify(window.__etLogs || [])") { logs in
                            if case .success(let text) = logs {
                                Log.write("driver: page console: \(text.prefix(1500))")
                            }
                        }
                        self?.call("window.__echotype.dialogs()") { dialogs in
                            if case .success(let text) = dialogs {
                                Log.write("driver: dialogs on page: \(text.prefix(500))")
                            }
                        }
                        self?.call("await window.__echotype.testMic()") { mic in
                            if case .success(let text) = mic {
                                Log.write("driver: direct mic test: \(text)")
                            }
                        }
                        self?.logButtonDump(context: "not-engaged gum=\(state.gum)")
                    }
                    completion(.failure(.buttonNotFound("mic didn't start: \(state.gum)")))
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self?.awaitEngagement(deadline: deadline, forensics: forensics, completion: completion)
                    }
                }
            }
        }
    }

    func submitDictation(completion: @escaping (Result<Void, Failure>) -> Void) {
        nativeClick(kind: "submit", completion: completion)
    }

    func cancelDictation(completion: ((Result<Void, Failure>) -> Void)? = nil) {
        nativeClick(kind: "cancel") { result in
            if case .failure(let error) = result {
                Log.write("driver: cancel -> \(error)")
            }
            completion?(result)
        }
    }

    func clearComposer(completion: (() -> Void)? = nil) {
        call("window.__echotype.clearComposer()") { _ in completion?() }
    }

    /// Polls the composer after submit until the transcript settles: dictation UI
    /// gone and text unchanged across two consecutive polls. Empty text after the
    /// dictation UI disappears (plus a grace period) resolves to "".
    func awaitTranscript(timeout: TimeInterval = 20,
                         completion: @escaping (Result<String, Failure>) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastText = ""
        var stableCount = 0
        var emptyGrace = 0

        func poll() {
            state { [weak self] result in
                guard self != nil else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let state):
                    if Date() > deadline {
                        completion(.failure(.timeout))
                        return
                    }
                    if !state.dictating {
                        if !state.composerText.isEmpty && state.composerText == lastText {
                            stableCount += 1
                            if stableCount >= 2 {
                                completion(.success(state.composerText))
                                return
                            }
                        } else if state.composerText.isEmpty {
                            // Transcription may still be in flight briefly after the UI closes.
                            emptyGrace += 1
                            if emptyGrace >= 12 { // ~3s of confirmed emptiness
                                completion(.success(""))
                                return
                            }
                        } else {
                            stableCount = 0
                        }
                    }
                    lastText = state.composerText
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
                }
            }
        }
        poll()
    }

    /// DIAG: full forensic sequence, run via ECHOTYPE_DIAG=1 without the hotkey.
    /// Logs evidence at each step; cancels any dictation it manages to start.
    func runDiagnostics(completion: (() -> Void)? = nil) {
        func step(_ label: String, _ expr: String, then: @escaping () -> Void) {
            call(expr) { result in
                switch result {
                case .success(let text): Log.write("diag: \(label) -> \(text.prefix(3400))")
                case .failure(let error): Log.write("diag: \(label) FAILED -> \(error)")
                }
                then()
            }
        }
        // The composer renders after didFinish; wait for the start button first.
        func waitForButton(_ tries: Int) {
            call("window.__echotype.btnInfo('start')") { result in
                if case .success("null") = result, tries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitForButton(tries - 1) }
                    return
                }
                run()
            }
        }
        // After the click: poll for engagement up to 60 s (the one observed success
        // engaged somewhere inside a 39 s gap), then dump everything.
        func pollEngagement(_ remaining: Int) {
            state { result in
                if case .success(let s) = result {
                    if s.dictating || s.gum != "none" {
                        Log.write("diag: ENGAGED after poll (dictating=\(s.dictating) gum=\(s.gum), \(60 - remaining)s)")
                        finish()
                        return
                    }
                }
                if remaining <= 0 {
                    Log.write("diag: never engaged after 60s")
                    finish()
                    return
                }
                if remaining % 10 == 0 { Log.write("diag: still waiting (\(remaining)s left)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pollEngagement(remaining - 1) }
            }
        }
        func finish() {
            step("state", "window.__echotype.state()") {
                step("netLog", "window.__echotype.netLog()") {
                    step("console", "JSON.stringify(window.__etLogs || [])") {
                        step("dialogs", "window.__echotype.dialogHTML()") {
                            Log.write("diag: === end ===")
                            self.cancelDictation()
                            completion?()
                        }
                    }
                }
            }
        }
        func run() {
            Log.write("diag: === begin ===")
            step("audioTest", "await window.__echotype.audioTest()") {
            step("micPermsSrc", "await window.__echotype.searchBundle('requestMicrophonePermissions')") {
            step("rafTest", "await window.__echotype.rafTest()") {
            step("handlerSrc", "window.__echotype.handlerSrc('start')") {
            step("state", "window.__echotype.state()") {
                step("permMic", "await window.__echotype.permMic()") {
                    step("devices", "await window.__echotype.devices()") {
                        step("netHook", "window.__echotype.netHook()") {
                            step("btnInfo(start)", "window.__echotype.btnInfo('start')") {
                                step("reactClick(start)", "window.__echotype.reactClick('start')") {
                                    pollEngagement(60)
                                }
                            }
                        }
                    }
                }
            }
            }
            }
            }
            }
        }
        waitForButton(20)
    }

    /// Logs every button on the page so selector breakage is diagnosable from the log.
    private func logButtonDump(context: String) {
        call("window.__echotype.dump()") { result in
            if case .success(let dump) = result {
                Log.write("driver: selector miss (\(context)); buttons on page: \(dump)")
            }
        }
    }
}
