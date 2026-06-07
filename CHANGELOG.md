# Changelog

All notable changes to EchoType are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/DevWizardHQ/EchoType/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/DevWizardHQ/EchoType/releases/tag/v1.0.0
