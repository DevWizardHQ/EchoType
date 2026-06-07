import Foundation

/// Every chatgpt.com DOM hook lives here so a ChatGPT UI change is a one-file patch.
///
/// Button lookups are ordered lists of case-insensitive regex patterns matched against
/// a button's `aria-label` and `data-testid`. The first pattern with a match wins.
///
/// Verified against chatgpt.com on 2026-06-07 with a LOGGED-IN session:
///   - composer:        div#prompt-textarea (contenteditable ProseMirror)
///                      ⚠ REMOVED from the DOM while dictation is active
///   - start dictation: button[aria-label="Start dictation"]
///   - while dictating: button[aria-label="Cancel dictation"], button[aria-label="Submit dictation"]
///   - send (never!):   button[aria-label="Send prompt"]
///   - voice mode:      button[data-testid="composer-speech-button"]  (NEVER click — opens voice chat)
///   - logged out:      button[data-testid="login-button"] present
/// Submit inserts the transcript into the composer (~0.5 s) and does NOT send the
/// message. `__echotype.dump()` logs the real buttons at runtime so a mismatch is
/// a quick patch (check ~/Library/Logs/EchoType.log).
enum Selectors {
    /// CSS selectors tried in order for the composer text area.
    static let composer = ["#prompt-textarea", "div.ProseMirror[contenteditable=\"true\"]"]

    /// CSS selector whose presence means the session is logged OUT.
    static let loggedOutMarker = "[data-testid=\"login-button\"]"

    /// Idle composer: the mic button that starts dictation.
    static let startDictation = ["^start dictation$", "^dictate", "dictation"]

    /// While dictating: the ✓ button that stops listening and transcribes.
    static let submitDictation = ["^submit dictation$", "submit.*dictation", "finish.*dictation", "^done$"]

    /// While dictating: the ✕ button that discards the dictation.
    static let cancelDictation = ["^cancel dictation$", "cancel.*dictation", "stop.*dictation", "discard.*dictation"]

    /// Safety only — patterns we must NEVER click (send message / open voice chat).
    static let neverClick = ["^send prompt$", "send-button", "composer-speech-button", "start voice"]

    /// Renders the pattern lists as a JS object literal for injection.
    static var js: String {
        func arr(_ patterns: [String]) -> String {
            "[" + patterns.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ",") + "]"
        }
        return """
        {
          composer: \(arr(composer)),
          loggedOutMarker: '\(loggedOutMarker.replacingOccurrences(of: "'", with: "\\'"))',
          start: \(arr(startDictation)),
          submit: \(arr(submitDictation)),
          cancel: \(arr(cancelDictation)),
          neverClick: \(arr(neverClick))
        }
        """
    }
}
