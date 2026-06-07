# EchoType

[![Release](https://img.shields.io/github/v/release/DevWizardHQ/EchoType)](https://github.com/DevWizardHQ/EchoType/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

System-wide voice dictation for macOS, powered by **ChatGPT's own web dictation** — no API keys, no per-use cost, no local model downloads.

**Hold the hotkey → speak → release → the transcript is pasted into whatever app has focus.**

## Features

- **Hold-to-talk** — hold **Right ⌥** (default, configurable), speak, release.
- **Hands-free mode** — double-tap the hotkey, talk freely, tap once to stop.
- **Dictation pill** — floating HUD with a live waveform, ✕ cancel and ✓ submit buttons that never steal focus from the app you're typing into.
- **History** — every transcript saved locally; pin, copy, multi-select delete.
- **Works everywhere** — any app with a text field: editors, browsers, chat apps.
- **Self-updating** — checks GitHub Releases and updates in place (SHA-256 verified).
- **Private by design** — audio goes only to chatgpt.com through your own logged-in session, exactly as if you used dictation on the website. History stays on your Mac.

## How it works

A hidden `WKWebView` keeps a logged-in chatgpt.com session. The hotkey drives ChatGPT's dictation buttons:

```
hotkey down → click "Start dictation"        (mic listens)
hotkey up   → click "Submit dictation"       (ChatGPT transcribes server-side)
            → read transcript from composer  (the message is NEVER sent)
            → clear composer → paste into the focused app
```

Pure Swift, single binary, zero external dependencies. ~150–250 MB while the page is loaded, ~30 MB idle in keep-warm mode.

## Install

### Download (recommended)

1. Grab `EchoType.dmg` from the [latest release](https://github.com/DevWizardHQ/EchoType/releases/latest).
2. Open it and drag **EchoType** onto the **Applications** shortcut.
3. First launch: the app is not notarized, so **right-click → Open → Open** (only needed once). Alternatively:
   ```sh
   xattr -dr com.apple.quarantine /Applications/EchoType.app
   ```

### Build from source

```sh
git clone https://github.com/DevWizardHQ/EchoType.git
cd EchoType
./scripts/build-app.sh
cp -R dist/EchoType.app /Applications/
open /Applications/EchoType.app
```

Requires macOS 14+ and Xcode command line tools.

## First run

1. Grant **Microphone** and **Accessibility** when prompted (Accessibility powers the global hotkey and paste).
2. The login window opens → sign in to ChatGPT (Google SSO works). Cookies persist across restarts.
3. Hold **Right ⌥** and talk. Release to paste.

## Usage

| Action | Gesture |
|---|---|
| Dictate | Hold hotkey, speak, release |
| Hands-free dictation | Double-tap hotkey, speak, tap once to finish |
| Cancel mid-dictation | Click ✕ on the pill |
| Finish & paste | Release the key (hold mode) or click ✓ |
| History | Menu bar icon → History… |

## Settings (menu bar → Settings…)

- **Hotkey** — any key or modifier, hold-to-talk.
- **Keep ChatGPT ready** — *Always* (instant dictation) or *Only while in use* (unloads after idle to free RAM; first dictation after idle waits a few seconds).
- **Launch at login.**
- **Updates** — automatic daily checks, or check manually any time.

## Troubleshooting

- **Hotkey does nothing** — System Settings → Privacy & Security → Accessibility → enable EchoType, then relaunch.
- **"Logged out" errors** — menu bar icon → *Log in to ChatGPT…* and sign in again.
- **Dictation stopped working after a ChatGPT redesign** — all DOM selectors live in [`Sources/EchoType/Selectors.swift`](Sources/EchoType/Selectors.swift); the app logs every button it sees to `~/Library/Logs/EchoType.log` on a selector miss. PRs welcome.
- **Anything else** — check `~/Library/Logs/EchoType.log`, and see [CONTRIBUTING.md](CONTRIBUTING.md) for the built-in diagnostic mode.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and selector patches are especially welcome — ChatGPT's UI changes from time to time.

## License

[MIT](LICENSE) © DevWizardHQ
