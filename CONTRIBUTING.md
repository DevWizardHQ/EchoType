# Contributing to EchoType

Thanks for your interest in improving EchoType!

## Getting started

```sh
git clone https://github.com/DevWizardHQ/EchoType.git
cd EchoType
./scripts/build-app.sh
open dist/EchoType.app
```

Requirements: macOS 14+, Xcode command line tools (Swift 5.9+).

## Project layout

| File | Role |
|---|---|
| `Sources/EchoType/AppDelegate.swift` | State machine (idle → engaging → listening → transcribing), menu bar |
| `Sources/EchoType/ChatGPTWebController.swift` | Hidden webview, login window, lifecycle policy |
| `Sources/EchoType/DictationDriver.swift` | JS bridge: click dictation buttons, read/clear composer, await transcript |
| `Sources/EchoType/Selectors.swift` | Every chatgpt.com DOM selector (one-file patch on UI changes) |
| `Sources/EchoType/HotkeyMonitor.swift` | Global event tap for the hold-to-talk hotkey |
| `Sources/EchoType/HUDController.swift` | Floating dictation pill (waveform, ✕ / ✓) |
| `Sources/EchoType/HistoryStore.swift` / `HistoryView.swift` | Transcript history |
| `Sources/EchoType/UpdateManager.swift` | GitHub Releases update check + self-update |

## When ChatGPT changes its UI

All DOM hooks live in `Sources/EchoType/Selectors.swift`. On a selector miss the
app logs every button on the page to `~/Library/Logs/EchoType.log` — update the
patterns in that one file and rebuild.

For deeper issues, run the built-in diagnostics and attach the log to your issue:

```sh
ECHOTYPE_DIAG=1 ./dist/EchoType.app/Contents/MacOS/EchoType
tail -f ~/Library/Logs/EchoType.log
```

## Pull requests

- Keep changes focused; one topic per PR.
- Match the existing code style (Swift, no external dependencies).
- Update `CHANGELOG.md` under **Unreleased** for user-visible changes.
- Verify the app builds and dictation works end to end before submitting.

## Reporting bugs

Open an issue with:

- macOS version and EchoType version (Settings → Updates).
- Steps to reproduce.
- Relevant lines from `~/Library/Logs/EchoType.log`.
