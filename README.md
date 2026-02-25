# Vibe Mouse

Vibe Mouse is a macOS menu bar utility that maps mouse and keyboard chords to fast desktop actions:

- screenshot capture to clipboard
- clipboard paste (`Cmd+V`)
- Dictation toggle

The app is built with SwiftUI/AppKit and runs as a menu bar extra (`LSUIElement`), so it stays lightweight and out of the Dock.

## Features

- Trigger screenshot mode with:
  - Left click + Right click chord
  - Caps Lock (optional, enabled by default)
- Optional side-button shortcuts:
  - Back + Forward chord -> paste clipboard (`Cmd+V`)
  - Forward button -> toggle Dictation
- Experimental Forward gesture mode:
  - Forward single-click -> Dictation
  - Forward drag + release -> area screenshot to clipboard
  - Forward double-click -> paste clipboard
- Adjustable screenshot chord timing window (20-200 ms)
- Menu bar status and a full Settings window for behavior + permissions

## Requirements

- macOS 13 or newer
- Swift 6.2 toolchain / Xcode with Swift 6.2 support (for source builds)
- Permissions:
  - Accessibility
  - Input Monitoring
  - Screen & System Audio Recording (Screen Recording)

For Dictation integration, set the macOS Dictation shortcut to `Control + Option + Command + D`.

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
- `Back + Forward`: paste clipboard (`Cmd+V`)
- `Forward`: toggle Dictation (and send `Return` when stopping Dictation)

All shortcuts can be enabled/disabled in **Settings -> Behavior**.

## Build and Run from Source

```bash
swift build
swift run vibe-mouse
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
- copies `.build/debug/vibe-mouse` into `Vibe Mouse.app`
- bumps `CFBundleVersion`
- signs with a local self-generated dev identity in `~/.vibe-mouse-signing`
- restarts the app

Optional env var:

- `VIBE_MOUSE_APP_PATH` to point to a non-default app bundle path

## Repo Layout

- `Sources/VibeMouse/` - app code (UI, event tap monitor, screenshot/paste/dictation services)
- `scripts/dev-restart.sh` - local build/sign/restart helper
- `INSTALL.md` - end-user install and troubleshooting notes
- `dist/` - packaged app/release artifacts

## Troubleshooting

- If shortcuts do not fire, verify all permissions and restart the app.
- If monitor status says event tap is unavailable, re-check Accessibility + Input Monitoring and relaunch.
- If screenshots fail, re-check Screen Recording permission.
- If Dictation does not toggle, confirm the Dictation shortcut matches `Control + Option + Command + D`.
