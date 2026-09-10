# Vibe Mouse Installation (macOS)

## Download

Download the latest app zip from GitHub Releases:

- `Vibe-Mouse-v0.1.0-macOS-arm64.zip`

This build is for Apple Silicon (`arm64`) Macs.

## Install

1. Unzip the release.
2. Move `Vibe Mouse.app` into either:
   - `/Applications`
   - `/Users/<your-user>/Applications`
3. Launch the app.

## First Launch (Gatekeeper)

The app is ad-hoc signed (not notarized), so macOS may block the first launch.

If that happens:

1. In Finder, right-click `Vibe Mouse.app`
2. Click `Open`
3. Confirm `Open`

## Required Permissions

The app needs all of these:

- `Accessibility`
- `Input Monitoring`
- `Screen & System Audio Recording` (Screen Recording)

Open the app's **Settings** window and use the **Permissions** section to request/open each permission page.

After granting permissions:

1. Quit `Vibe Mouse`
2. Reopen it
3. Click `Refresh Status`

The status should show it is listening for screenshot, keyboard, and mouse shortcuts.

## Using It

Trigger interactive screenshot mode with any of these:

- Press **Caps Lock** (Vibe Mouse overrides Caps Lock while active and uses it as a screenshot key)
- Press **left click + right click** nearly at the same time

Then click-drag to capture an area. The screenshot is copied to the clipboard.

If you want normal Caps Lock behavior, disable **Settings → Behavior → Use Caps Lock for screenshot**.

Palm-friendly Windows-style shortcuts are translated while Vibe Mouse is enabled:

- **Ctrl + Shift + C** copies the selected name or other text and immediately searches it in a new tab in your default browser.
- **Ctrl + Option + V** searches the copied name or other text in a new tab in your default browser.
- **Alt + Space** opens Spotlight with macOS Command+Space behavior.
- **Alt + Tab** opens a thumbnail grid of individual windows from all apps. Keep Alt held and tap Tab to cycle, add Shift to go backwards, or use the arrows to move around the grid, then release Alt to choose. Escape cancels. Command+Tab keeps the native macOS app switcher.
- **Command + Backtick**, **Ctrl + Backtick**, or **Alt + Backtick** opens a preview of the current app's windows. Hold the modifier and keep tapping the backtick/tilde key to cycle; add **Shift** to reverse, release to choose, or press **Escape** to cancel. Minimized windows are included. Thumbnails need Screen Recording permission and macOS 14 or later; otherwise titles and app icons are shown.
- **Ctrl + V** pastes with macOS Command+V.
- **Ctrl + C**, **Ctrl + T**, **Ctrl + W**, and similar shortcuts map to their Mac Command equivalents.
- **Ctrl + Enter** sends or submits in apps that use macOS Command+Enter.
- **Ctrl + left click** opens links with macOS Command-click behavior.
- **Ctrl + Backspace** (Mac Delete) deletes the previous word; **Ctrl + forward Delete** deletes the next word.
- **Ctrl + Home/End** moves to document start/end; add Shift to select.
- **Ctrl + Tab** and **Ctrl + Shift + Tab** are left alone so Chrome can cycle tabs.
- **Ctrl + Arrow**, **Ctrl + Option + Arrow**, or **Command + Arrow** controls the focused window.
- Repeating **Ctrl + Left/Right** from a side snap throws the window to the neighboring monitor.
- Repeating **Command + Left/Right** from a side snap throws the window to the neighboring monitor.
- **Ctrl + Shift + Left/Right** or **Command + Shift + Left/Right** moves the focused window to the physically neighboring monitor.
- **Ctrl + Option + Shift + Left/Right** also moves directly between monitors.
- **Up** after a half snap moves to a top quarter; another Up maximizes. **Down** steps from top quarter to half, bottom quarter, then the saved original size. Down after maximize restores the saved size.
- Moving monitors preserves half/quarter/maximized placement. A floating window keeps its size when it fits.
- Hold-to-repeat is ignored for window commands; tap again for the next step.

See **Settings → Shortcut guide** or the [full key guide](README.md#usage).
For word movement and selection with Ctrl+Arrow, turn off **Settings → Behavior → Use Ctrl+Arrow for windows**. Ctrl+Option+Arrow and Command+Arrow remain available for windows.

Mouse controls:

- **Center click** over a browser tab closes that tab.
- **Center click** over a link or Gmail inbox message opens it in a new browser tab.
- **Center click** elsewhere toggles Windows-style auto-scroll; farther from the anchor scrolls faster.
- **Left click** stops auto-scroll when it is active.
- Back and Forward side buttons pass through normally.

## If The App Is Not Listed In macOS Permission Pickers

Use the `+` button in the macOS Settings permission page, then:

1. Press `Shift + Command + G`
2. Enter the folder where you installed the app:
   - `/Applications`
   - or `/Users/<your-user>/Applications`
3. Select `Vibe Mouse.app`

## Troubleshooting

- If the app says permissions are granted but the chord still does nothing, enable `Input Monitoring` and restart the app.
- If you install a different local build (especially from source), macOS may require permissions to be granted again.
