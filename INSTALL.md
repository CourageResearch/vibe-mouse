# Vibe Mouse Installation (macOS)

## Download

Download the latest app zip from GitHub Releases:

- `Mouse-Chord-Shot-v0.1.0-macOS-arm64.zip`

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

The status should show it is listening for the mouse chord.

## Using It

Trigger interactive screenshot mode with any of these:

- Press **Caps Lock** (Vibe Mouse overrides Caps Lock while active and uses it as a screenshot key)
- Press **F4/Search**
- Press **left click + right click** nearly at the same time

Then click-drag to capture an area. The screenshot is copied to the clipboard.

If you want normal Caps Lock behavior, disable **Settings → Behavior → Use Caps Lock for screenshot**.

If enabled in the app:

- Press **Back + Forward side buttons together** to paste clipboard (`Cmd+V`).
- Press **Back side button alone** to pass Back through to apps normally.
- Press **Forward side button** to toggle system Dictation on/off.
- When Dictation is toggled off from Vibe Mouse, it automatically sends **Return**.

### Experimental Forward Gestures (Preview)

Enable this in **Settings → Behavior** to test an alternate control scheme:

- **Single-click Forward**: toggle Dictation
- **Press + drag Forward, then release**: capture selected area to clipboard
- **Double-click Forward**: paste clipboard (`Cmd+V`)

## Configure Dictation Shortcut (for Forward Button)

Set macOS Dictation to use this shortcut so Vibe Mouse can toggle it:

1. Open **System Settings → Keyboard → Dictation**
2. Ensure Dictation is turned on
3. Set Dictation shortcut to **Control + Option + Command + D**

Vibe Mouse sends that shortcut when you press the Forward side button.

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
