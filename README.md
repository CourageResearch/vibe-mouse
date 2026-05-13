# Vibe Mouse

Vibe Mouse is a macOS menu bar utility that maps mouse and keyboard chords to fast desktop actions:

- screenshot capture to clipboard
- palm-friendly Windows-style `Ctrl` shortcuts
- center-click auto-scroll

The app is built with SwiftUI/AppKit and runs as a menu bar extra (`LSUIElement`), so it stays lightweight and out of the Dock.

## Features

- Trigger screenshot mode with:
  - Left click + Right click chord
  - Caps Lock (optional, enabled by default)
- Screenshots are copied to the clipboard without auto-pasting
- Palm-friendly keyboard remaps:
  - `Ctrl+V`, `Ctrl+C`, `Ctrl+T`, `Ctrl+W`, and similar Windows muscle-memory shortcuts are translated to Mac `Command` shortcuts
  - `Ctrl+Tab` and `Ctrl+Shift+Tab` are left alone for browser tab cycling
  - `Ctrl+Alt+Left/Right/Up/Down` snaps the focused window like Windows
  - Repeating `Ctrl+Alt+Left/Right` from a side snap throws the window to the neighboring monitor
  - `Ctrl+Alt+Shift+Left/Right` moves the focused window to the physically neighboring display
- Center click toggles Windows-style auto-scroll
- Adjustable screenshot chord timing window (20-200 ms)
- Menu bar status and a full Settings window for behavior + permissions

## Requirements

- macOS 13 or newer
- Swift 6.2 toolchain / Xcode with Swift 6.2 support (for source builds)
- Permissions:
  - Accessibility
  - Input Monitoring
  - Screen & System Audio Recording (Screen Recording)

## Install (Prebuilt App)

1. Download the latest release zip from the repo Releases page.
2. Unzip and move `Vibe Mouse.app` to:
   - `/Applications`, or
   - `/Users/<your-user>/Applications`
3. Launch the app.

On first launch, macOS Gatekeeper may block it because local builds are ad-hoc signed (not notarized). If needed:

1. In Finder, right-click `Vibe Mouse.app`.
2. Click `Open`.
3. Confirm `Open`.

## First-Run Permissions

Open **Settings** in Vibe Mouse and grant the required permissions. After granting:

1. Quit Vibe Mouse.
2. Reopen it.
3. Click `Refresh Status` in the app settings.

If the app is not listed in a macOS privacy pane, use the `+` button and add `Vibe Mouse.app` from your Applications folder.

## Usage

Default actions:

- `Caps Lock` or `Left + Right mouse chord`: start interactive screenshot capture
- `Ctrl+V`: paste the clipboard with Windows muscle memory
- `Ctrl+Tab`: cycle browser tabs
- `Ctrl+Alt+Left/Right`: snap the focused window to the left or right half
- `Ctrl+Alt+Left/Right`, repeated from a side snap: move to the neighboring monitor
- `Ctrl+Alt+Up`: maximize the focused window, or snap a side-snapped window to the top quarter
- `Ctrl+Alt+Down`: restore from maximize, or snap a side-snapped window to the bottom quarter
- `Ctrl+Alt+Shift+Left/Right`: move the focused window across monitors
- `Center click`: toggle auto-scroll

All shortcuts can be enabled/disabled in **Settings -> Behavior**.

## Build and Run from Source

```bash
./scripts/dev-run.sh
```

By default, `dev-run` refreshes the installed app bundle and launches that copy so the app you click in macOS stays in sync with the latest local build.
If you explicitly want the raw repo binary instead, run:

```bash
VIBE_MOUSE_DIRECT_RUN=1 ./scripts/dev-run.sh
```

You can also open the package in Xcode:

```bash
open Package.swift
```

## Dev Restart Workflow

For faster iteration against an installed app bundle, use:

```bash
./scripts/dev-restart.sh
```

What it does:

- builds the package
- uses repo-local SwiftPM/module cache directories so local toolchain caches do not need writable home-directory paths
- copies `.build/debug/vibe-mouse` into `Vibe Mouse.app`
- bumps `CFBundleVersion`
- signs with a local self-generated dev identity in `~/.vibe-mouse-signing`
- restarts the app
- keeps the installed app bundle as the default development launch target, which avoids version confusion between a repo binary and an older app in `/Applications`

If you prefer the raw Swift commands, this repo expects a writable local scratch path:

```bash
swift build --disable-sandbox --scratch-path .build/scratch
$(swift build --disable-sandbox --scratch-path .build/scratch --show-bin-path)/vibe-mouse
```

Optional env var:

- `VIBE_MOUSE_APP_PATH` to point to a non-default app bundle path

## Repo Layout

- `Sources/VibeMouse/` - app code (UI, event tap monitor, screenshot, auto-scroll, and window tiling services)
- `scripts/dev-restart.sh` - local build/sign/restart helper
- `INSTALL.md` - end-user install and troubleshooting notes
- `dist/` - packaged app/release artifacts

## Troubleshooting

- If shortcuts do not fire, verify all permissions and restart the app.
- If monitor status says event tap is unavailable, re-check Accessibility + Input Monitoring and relaunch.
- If screenshots fail, re-check Screen Recording permission.
