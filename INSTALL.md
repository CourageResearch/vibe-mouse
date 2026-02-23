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

Trigger interactive screenshot mode by pressing **left click + right click** nearly at the same time.

Then click-drag to capture an area. The screenshot is copied to the clipboard.

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
