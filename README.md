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
- Palm-friendly keyboard and click remaps:
  - `Ctrl+Shift+C` copies the selected name or other text and immediately searches it in a new default-browser tab
  - `Alt+Space` is translated to `Command+Space` for Spotlight
  - `Alt+Tab` opens a grid of individual windows from all apps, with thumbnails and app icons; `Alt+Shift+Tab` cycles backwards
  - `Command+Backtick`, `Ctrl+Backtick`, or `Alt+Backtick` opens a thumbnail switcher for windows in the current app
  - `Ctrl+V`, `Ctrl+C`, `Ctrl+T`, `Ctrl+W`, and similar Windows muscle-memory shortcuts are translated to Mac `Command` shortcuts
  - `Ctrl+Enter` is translated to `Command+Enter` for sending/submitting in apps that support it
  - `Ctrl+left-click` is translated to `Command+left-click` for opening links in Chrome-style browsers
  - `Ctrl+Delete` is translated to `Option+Delete` for deleting one word at a time
  - `Ctrl+Tab` and `Ctrl+Shift+Tab` are left alone for browser tab cycling
  - `Command+Arrow`, `Ctrl+Arrow`, or `Ctrl+Option+Arrow` snaps the focused window
  - Repeating `Ctrl+Left/Right` from a side snap throws the window to the neighboring monitor
  - Add `Shift+Left/Right` to any window binding to move directly to the neighboring display, preserving half/quarter placement
  - Window state and restore size are remembered per window; rapid taps are processed in order
  - Optional typing mode restores Ctrl+Arrow word navigation and selection
- Center click closes browser tabs, opens links or Gmail inbox messages in a new tab, and toggles Windows-style auto-scroll elsewhere
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

Alt is the Mac **Option (⌥)** key. Mac **Delete** is the backward-delete/Backspace key; an external keyboard's **Delete** usually deletes forward.

The full guide is also available in **Settings → Shortcut guide**.

| Keys | Action |
| --- | --- |
| Command+Arrow, Ctrl+Arrow, or Ctrl+Option+Arrow | Window controls described below |
| Ctrl+Shift+C | Copy selected text and search Google in your default browser |
| Ctrl+C / X / V / A | Copy / cut / paste / select all |
| Ctrl+Z / Y / Shift+Z | Undo / redo / redo |
| Ctrl+T / W / Shift+T | New tab / close tab / reopen closed tab in browsers |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous browser tab |
| Ctrl+L / F / S / P | Address bar / find / save / print |
| Ctrl+N / O / R | New / open / reload, where supported |
| Ctrl+B / I / U / K | Bold / italic / underline / link, where supported |
| Ctrl+D | App's Command+D action, e.g. bookmark in Chrome |
| Ctrl+1…9 / 0 / minus / equals | App's Command equivalent: tab selection or zoom, depending on the app |
| Ctrl+Enter | Send/submit in apps supporting Command+Enter |
| Ctrl+Backspace / Ctrl+forward Delete | Delete previous / next word |
| Ctrl+Home / End | Document start / end; add Shift to select |
| Alt+Tab / Alt+Shift+Tab | Preview individual windows from all apps; cycle forward / backwards; release Alt to choose |
| Command+backtick / Ctrl+backtick / Alt+backtick | Preview windows in the current app; release the modifier to choose |
| Add Shift while cycling windows | Cycle backwards; Escape cancels, Enter chooses |
| Alt+Space | Spotlight |
| Caps Lock (optional) / left+right mouse chord | Select a screenshot area; copy it to the clipboard |
| Ctrl+left-click | Command-click behavior, including opening browser links in new tabs |
| Middle click on a tab / link / Gmail row | Close tab / open new tab / open message in new tab |
| Middle click elsewhere | Start auto-scroll; distance from the anchor controls speed |
| Escape / middle click / left click | Stop auto-scroll |

### Window previews

Hold **Command**, **Ctrl**, or **Alt** and tap the **backtick/tilde key** (\` / ~) to preview the current app's windows, including Chrome windows. Keep tapping to cycle; add **Shift** to go backwards. Release the modifier to focus the selected window. While the preview is open, **Left/Right** also changes selection, **Enter** chooses, and **Escape** cancels. A quick tap switches immediately without waiting for thumbnails. Ctrl+Tab still cycles browser tabs.

The switcher includes minimized windows and restores one when selected. Thumbnails require **Screen Recording** permission and macOS 14 or later; without them, window titles and app icons remain usable. Previews stay in memory and are discarded when the switcher closes.

**Alt+Tab** opens an **all-windows grid** with a separate thumbnail, title, and app icon for each window. Keep **Alt** held and tap **Tab** to continue cycling; add **Shift** to cycle backwards. **Left/Right** moves between windows, **Up/Down** moves between rows, **Enter** chooses, and **Escape** cancels. Release **Alt** to activate the selected window's app and bring that specific window forward. The grid includes minimized windows and scrolls to keep the selection visible. **Command+Tab** still uses the native macOS app switcher.

### Window keys

Plain arrows stay with the focused app for cursor movement or scrolling. Shift+arrows select text. Use **Command (⌘)+Arrow** on the MacBook keyboard to control windows. Fn/Globe+Arrow keeps its normal navigation behavior.

Use any of the window modifier combinations above, then:

- **Left/Right:** snap to that half. Repeat toward its outside edge to move to the opposite half of the next monitor. Another press advances to that monitor's other half. At the last monitor, stay put.
- **Up:** half → top quarter → maximize. A bottom quarter moves to the top of the same column.
- **Down:** top quarter → half → bottom quarter → restore. From maximize, restore the window's saved size and position.
- **Shift+Left/Right:** move straight to the neighboring display. A half, quarter, or maximized window fits the new display; a floating window preserves its size and relative placement where space allows.
- Quarter-window horizontal moves preserve the top/bottom row.
- Each tap performs one step. Holding an arrow does not throw repeatedly.
- Manual movement/resizing starts a new placement history. Full-screen Spaces are left alone; exit full screen before tiling.
- Apps with a minimum window size may occupy more than a half/quarter; the app aligns the accepted size and reports this in Last action.

**Typing option:** turn off **Settings → Behavior → Use Ctrl+Arrow for windows** to use Ctrl+Left/Right for word movement and Ctrl+Shift+Left/Right for word selection. Ctrl+Up/Down moves to document start/end (Shift selects). Ctrl+Option+Arrow and Command+Arrow continue to control windows. The existing Ctrl+Arrow window binding remains on by default.

**Settings:** the master switch controls all remaps. Copy & Search and Caps Lock capture have separate switches; turning off Copy & Search leaves ordinary Ctrl-to-Command translation active. These are global Mac Command mappings, so terminal Ctrl+C/Ctrl+Z behavior is also affected while enabled.

## Build and Run from Source

Run the geometry and keyboard lifecycle regression tests with:

```bash
swift test --disable-sandbox --scratch-path .build/scratch
```

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
