# Changelog

All notable changes to EchoType are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.5] - 2026-09-06

### Fixed

- Dictation still not pasting into terminals after 1.0.4: the system-wide `AXFocusedUIElement` lookup returns nothing for some apps (terminals), so detection saw "no focused element" and diverted to the clipboard. It now falls back to the frontmost application's own focused element, which those apps do expose.

## [1.0.4] - 2026-09-06

### Fixed

- Dictation not pasting into terminals (Terminal.app, iTerm2, Warp, Ghostty) and other apps with non-standard accessibility: the transcript was diverted to the clipboard instead of being typed at the cursor. Paste detection is now biased toward pasting — it only falls back to the clipboard when there is clearly no text target (no focused element, or a recognized non-text control such as a button). The focused element's role and text attributes are logged to aid diagnosis.

## [1.0.3] - 2026-09-05

### Fixed

- No-network handling: a dictation or login attempt while offline no longer opens a blank, frozen window and hangs for 25 seconds. Connectivity is monitored, offline is detected immediately, and the app fails fast with a clear message.
- Login window reopen loop: the ChatGPT login window is no longer auto-opened on every logged-out check (which re-centered the window and stole focus repeatedly on a fresh install). It now opens only from the menu bar, on user action.

### Added

- Clipboard fallback for dictation: if an editable text field is focused, the transcript is pasted as before; if nothing editable is focused, it is left on the clipboard (with a "Copied to clipboard" notice) instead of being lost.
- Offline placeholder page with a Retry button, shown in the login window when there is no connection, plus automatic recovery when the network returns.
- Menu-bar offline indicator (icon and menu item) and a matching HUD message.

## [1.0.1] - 2026-06-07

### Fixed

- Dictation silently failing after switching Spaces or on a fresh launch: the hidden ChatGPT window could be left unordered or behind on another Space, which froze the page and stalled dictation before the mic ever opened.
- Visible ghost window and shadow over the desktop: the hidden window is now parked offscreen (a 2-pt sliver stays on the edge) with its shadow disabled.
- Long dictations (no time limit): transcript collection now waits on an inactivity window that extends while ChatGPT is still transcribing, instead of a fixed 20-second cap; an absent composer is no longer mistaken for an empty transcript.
- Keep-warm idle unload no longer tears the page down mid-dictation.
- Submitting long dictations no longer reports a false failure when the dictation UI closes during the submit confirmation poll.

### Changed

- Dictation is now driven by ChatGPT's own keyboard shortcuts (⌃⇧D to start/submit, Esc to cancel) with button clicks as fallback — far more robust against page changes.
- The page reloads to self-heal only after two consecutive engagement failures, with full forensics (window state, render-pipeline fps) logged.

## [1.0.0] - 2026-06-07

### Added

- Hold-to-talk dictation: hold the hotkey (default **Right ⌥**), speak, release — the transcript is pasted into whatever app has focus.
- Hands-free mode: double-tap the hotkey to keep the mic open, tap once to stop and transcribe.
- Dictation HUD pill with live waveform, cancel (✕) and submit (✓) buttons that never steal focus from the target app.
- Transcription history window: pinned items, per-item copy/pin/delete, checkbox multi-select with select-all and delete-selected, clear-all.
- Menu bar app with login state indicator, settings, and history access.
- Configurable hotkey (any key or modifier), webview lifecycle policy (always ready / keep warm), launch at login.
- Automatic update checks against GitHub Releases with one-click in-place self-update (SHA-256 verified).
- Diagnostic mode (`ECHOTYPE_DIAG=1`) and file logging at `~/Library/Logs/EchoType.log` for troubleshooting ChatGPT UI changes.

[Unreleased]: https://github.com/DevWizardHQ/EchoType/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/DevWizardHQ/EchoType/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/DevWizardHQ/EchoType/releases/tag/v1.0.0
