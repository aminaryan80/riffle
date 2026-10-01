# Riffle

A tiny, custom [AltTab](https://alt-tab-macos.netlify.app/)-style **window** switcher for macOS.

- Switches between **windows**, not apps.
- Shows a clean list of **app icon + window title** only — no window previews/thumbnails (which also means it never needs the Screen Recording permission).
- Sees windows in **all Spaces (virtual desktops)**, not just the current one — scopes are about *physical monitors*, never Spaces. Switching to a window in another Space jumps there automatically.
- Multiple hotkeys, each with its own purpose, fully customizable via a JSON config:
  - **⌘ Tab** — cycle through the windows on the **active physical monitor** (the monitor with the focused window), across all its Spaces.
  - **⌘ `** — cycle through windows on **all monitors**. With a single monitor this behaves exactly like ⌘Tab.
  - **⌥ Tab** — cycle through the windows of the **frontmost app** (e.g. jump between open Chrome windows while in Chrome).
- Hold the modifier and keep pressing the key to move down the list; add **Shift** to move backwards; release the modifier to switch to the selected window; press **Esc** to cancel.
- A **Settings window** (menu bar icon → Settings…) to add/remove/re-record shortcuts, choose what each one shows, tune the switcher's appearance (list size and background opacity), and exclude apps from all lists — no config-file editing needed.
- **Gaze Focus (experimental, off by default)** — uses the webcam to tell which window you're looking at: hold a shortcut, look, release to focus; or let focus follow your gaze after a short dwell. Everything runs on-device with Apple's Vision framework — no extra hardware, no network. See [Gaze Focus](#gaze-focus-experimental).
- Runs as a menu-bar-only app (no Dock icon).

## Requirements

- macOS 13 or later (Apple Silicon or Intel).
- Xcode Command Line Tools (for building): `xcode-select --install`

## Install

From this project directory:

```bash
./install.sh
```

That script:

1. Compiles the app in release mode (`swift build -c release`).
2. Assembles and ad-hoc code-signs `dist/Riffle.app`.
3. Resets any stale Accessibility permission (see note below) so a reinstall grants cleanly.
4. Copies it to `/Applications/Riffle.app` and launches it.

### First run: grant Accessibility access

macOS requires Accessibility access to list windows and intercept ⌘Tab:

1. On first launch you'll get a system prompt — click **Open System Settings**.
   (Or go there manually: **System Settings → Privacy & Security → Accessibility**.)
2. Enable **Riffle** in the list.
3. That's it — the app detects the grant automatically within a couple of seconds. Hold **⌘** and press **Tab**.

> While Riffle is running, it takes over ⌘Tab from the built-in macOS app switcher. Quit Riffle (menu bar icon → Quit) to get the native switcher back.

### Start at login (optional)

**System Settings → General → Login Items** → click **+** → select `/Applications/Riffle.app`.

## Updating

Riffle updates itself from [GitHub Releases](https://github.com/aminaryan80/riffle/releases) — no package manager needed.

- **Menu bar icon → Check for Updates…** compares the running version against the latest release and reports the result.
- A silent check also runs a few seconds after each launch; it only speaks up when a newer release exists.

When an update is available, Riffle downloads the release's app zip, shows a progress window, then replaces `/Applications/Riffle.app` (or wherever it's installed) and relaunches — all in-app.

> **Accessibility re-grant after updating:** Riffle is ad-hoc code-signed, so every build has a different signature and macOS treats an update as a new app for permission purposes. The updater clears the stale Accessibility grant on your behalf (`tccutil reset Accessibility com.amin.riffle`), so after it relaunches you'll need to re-enable **Riffle** once in **System Settings → Privacy & Security → Accessibility**. This is the same reason `install.sh` resets the grant.

## Usage

| Action | Keys |
|---|---|
| Cycle windows on the active screen | Hold ⌘, tap **Tab** |
| Cycle windows on all screens | Hold ⌘, tap **`** (backtick) |
| Cycle windows of the current app | Hold ⌥ (option), tap **Tab** |
| Move backwards through the list | Add **Shift** (e.g. ⌘⇧Tab) |
| Move around the list | **↓/→** forward, **↑/←** backward (while the list is open) |
| Switch to the selected window | Release ⌘ |
| Cancel without switching | **Esc** |

The list is in most-recently-used order — Riffle tracks window focus while it runs (macOS has no built-in "last focused" timestamp), so the order is true MRU across all Spaces and monitors. Windows not focused since the app launched fall back to front-to-back stacking order. The selection starts on the *second* item, so a quick ⌘Tab tap-and-release jumps to your previous window. Minimized windows and phantom helper windows that some apps create (Chrome, Acrobat, …) are hidden — only real, open windows are listed.

## Configuration

Open the menu bar icon → **Settings…**. From there you can:

- **Shortcuts** — click a shortcut to re-record it (just press the new key combination; Esc cancels), pick what each one shows from the dropdown (*active monitor / all monitors / current app / the window I'm looking at*), remove shortcuts, or add new ones. Changes apply immediately.
- **Appearance** — scale the whole switcher with the *List size* slider (it still grows automatically for shorter lists) and drag *Background* from glassy (translucent blur) to fully solid.
- **Gaze Focus** — enable the camera, pick which one, calibrate, and choose between shortcut-driven and automatic (dwell) switching. See below.
- **Excluded Apps** — add any running app (or pick one from disk) to hide all of its windows from every list; remove it to bring it back.

A shortcut needs at least one of ⌘, ⌥, ⌃. Record without ⇧ — then Shift automatically means "cycle backwards" for that shortcut.

## Gaze Focus (experimental)

Riffle can use your Mac's camera to work out which window you're looking at and focus it. It is built to tell *windows* apart, not to point precisely: with a normal webcam expect it to be reliable for picking a monitor or one of a few large windows, and unreliable for small windows in a crowded layout.

### Setup

1. Menu bar icon → **Settings…** → **Gaze Focus** → tick **Enable gaze tracking**. macOS asks for Camera access once; the camera's indicator light stays on while tracking is enabled.
2. Click **Calibrate…** (also in the menu bar menu). A dot visits a grid of points on each monitor — follow it with your eyes, keep your head still, sit the way you normally do. Afterwards a ring shows live where Riffle thinks you're looking so you can judge the result; press any key to finish. Esc cancels at any point.
3. Pick how you want to switch:
   - **Shortcut (recommended)** — enabling gaze adds a `⌘⌥ Tab` shortcut set to *The window I'm looking at* (if that combination was free). Hold it, a frame follows your gaze from window to window, release to focus the framed window. Any shortcut can be set to this scope.
   - **Automatic (dwell)** — tick *Switch focus automatically when I look at a window* and set how long a look counts. Riffle waits until you've stopped typing (1 s) and mousing before switching, never switches while a switcher list is open, and flashes a frame around the window it just focused so it's clear why focus moved.

Calibration is per monitor layout (docked vs. laptop-only each keep their own) and goes stale if you move the camera, the monitor, or your chair much — just recalibrate. The Settings window shows camera, calibration and tracking status.

### Tips

- Camera placement matters more than anything: it should sit on the monitor you look at most, roughly at eye level. A 1080p external webcam, or an iPhone via Continuity Camera, gives much better eye detail than a built-in camera — but turn **Center Stage off** (Control Center → Video Effects) since its auto-framing moves the picture under the tracker.
- Even, front-facing light. Strong backlight (a window behind you) is the most common cause of a failed calibration.
- Glasses are usually fine; heavy reflections or dark lenses aren't.

### Privacy

Frames go from the camera straight into Apple's on-device Vision framework and are discarded. Nothing is recorded, saved, or sent anywhere; the only thing written to disk is a few dozen calibration numbers in `~/Library/Application Support/Riffle/gaze-calibration.json`. Screen Recording permission is still not needed.

### Limitations

- Head movement the calibration didn't see (leaning in, sliding your chair) shifts the estimate until you recalibrate.
- Monitors far off the camera's axis are less accurate than the one it sits on.
- This is a deliberately dependency-free implementation; commercial webcam trackers with dedicated models (e.g. Beam) are considerably more accurate. The gaze backend is behind a small protocol so one of those could be added later.

### Config file (advanced)

Settings are stored in a JSON file, so you can also edit or version-control it directly (relaunch the app after hand-editing):

```
~/Library/Application Support/Riffle/config.json
```

Default config:

```json
{
  "bindings": [
    { "key": "tab", "modifiers": ["cmd"],    "scope": "activeScreen" },
    { "key": "`",   "modifiers": ["cmd"],    "scope": "allScreens" },
    { "key": "tab", "modifiers": ["option"], "scope": "activeApp" }
  ],
  "excludedApps": ["com.spotify.client"]
}
```

`excludedApps` holds bundle identifiers (app names also work). Each binding has:

- **`key`** — one of: letters `a`–`z`, digits `0`–`9`, `tab`, `space`, `` ` `` (also `grave`/`backtick`), punctuation (`-`, `=`, `[`, `]`, `\`, `;`, `'`, `,`, `.`, `/`), `f1`–`f12`, `left`/`right`/`up`/`down`.
- **`modifiers`** — any combination of `cmd`, `option` (or `alt`), `ctrl`, `shift`. At least one is required; the switcher stays open while these are held and commits when released. Shift is best left out — it's automatically the "go backwards" key for any binding that doesn't require it.
- **`scope`** — what the binding cycles through (all scopes include windows in other Spaces):
  - `activeScreen` — only windows on the physical monitor containing the currently focused window.
  - `allScreens` — every window on every monitor.
  - `activeApp` — only windows belonging to the frontmost app (on any monitor).
  - `gaze` — no list: hold, look at a window, release to focus it (needs Gaze Focus enabled and calibrated).

Two more optional keys tune the switcher's look (or use the Settings window):

- **`listScale`** — multiplier over the dynamic row sizing (clamped to a sensible range).
- **`backgroundOpacity`** — `0` for a fully glassy blur, `1` for a solid background.

Gaze Focus settings live under an optional `gaze` object: `enabled`, `dwellEnabled`, `dwellSeconds` (0.3–2.0), `cameraID` (an `AVCaptureDevice` unique ID; omit for the system default).

Add as many bindings as you like. Example — `option+tab` for all screens instead of `` cmd+` ``:

```json
{ "key": "tab", "modifiers": ["option"], "scope": "allScreens" }
```

## Uninstall

```bash
osascript -e 'quit app "Riffle"'
rm -rf /Applications/Riffle.app
rm -rf ~/Library/Application\ Support/Riffle
```

Then remove Riffle from **System Settings → Privacy & Security → Accessibility** (and **Camera**, if you enabled Gaze Focus).

## Troubleshooting

- **Hotkeys don't work while a terminal is focused (native ⌘Tab appears instead)** — that terminal has **Secure Keyboard Entry** enabled, which makes macOS hide keystrokes from all event taps while it's focused (by design; nothing can bypass it). The menu bar icon turns into a ⚠️ warning triangle while this is happening. To fix:
  - **Terminal.app**: menu bar → **Terminal** → untick **Secure Keyboard Entry**.
  - **iTerm2**: menu bar → **iTerm2** → untick **Secure Keyboard Entry**.
  - Note that some password managers toggle secure input briefly while their password fields are focused — that's normal and clears on its own.
- **⌘Tab still opens the native macOS switcher everywhere** — Accessibility access isn't granted (or was granted to an older build). Remove Riffle from the Accessibility list, re-add it (the **+** button, select `/Applications/Riffle.app`), then relaunch the app.
- **After rebuilding/reinstalling, hotkeys stopped working** — the ad-hoc code signature changes with each build, so macOS may treat it as a different app while the old grant lingers (the toggle looks on but doesn't apply). `install.sh` now clears the stale entry automatically (`tccutil reset Accessibility com.amin.riffle`) and the app re-prompts, so just re-enable **Riffle** in the Accessibility list after reinstalling. If you copied the app by hand instead of using `install.sh`, run that `tccutil` command yourself, then relaunch.
- **A hotkey does nothing** — check the key/modifier names in `config.json` against the lists above, then relaunch. Malformed config falls back to the defaults. Key codes assume an ANSI (US-style) physical layout.
- **An app's windows never appear in the list** — windows in other Spaces are found via the same accessibility side channel AltTab uses; a few apps with non-native toolkits (LibreOffice, some Java apps) don't answer those queries for windows outside the current Space and can't be listed. Switch to their Space once and they'll appear.
- **The gaze shortcut just beeps** — Gaze Focus is off, not calibrated for the current monitor layout, or the camera isn't available. Open Settings → Gaze Focus and read the status line; **Calibrate…** fixes the common case.
- **Gaze picks the wrong window / drifts** — recalibrate (menu bar → Calibrate Gaze…), especially after moving the camera, monitor or chair. If it's consistently off in one direction, your posture during calibration differed from how you actually sit; calibrate while sitting normally. Make sure Center Stage is off.
- **Calibration says it couldn't see your eyes** — face the camera squarely, add front light, remove strong backlight. If you wear glasses, tilt them slightly to kill reflections.
- **Is it running?** — look for the small window icon in the menu bar.

## Project layout

```
Package.swift                       Swift Package Manager manifest
Sources/Riffle/
  main.swift                        entry point
  AppDelegate.swift                 event tap (hotkey interception), menu bar item, permissions
  Config.swift                      settings storage, editing API, key/modifier resolution
  SettingsWindow.swift              the Settings UI (shortcut recorder, scopes, appearance, gaze, excluded apps)
  WindowEnumerator.swift            window listing across Spaces + focusing, monitor detection, caching
  PrivateAX.swift                   private accessibility APIs for windows in other Spaces
  SwitcherController.swift          trigger → cycle → commit/cancel state machine
  SwitcherPanel.swift               the floating icon+title list UI
  Updater.swift                     in-app updater (GitHub Releases): check, download, swap, relaunch
  Gaze/
    GazeTypes.swift                 GazeSource protocol, sample/feature types, screen-coordinate helpers
    CameraCapture.swift             AVCaptureSession wrapper (camera list, permission, frames)
    FaceTracker.swift               Vision face pose + eye/pupil landmarks → GazeFeatures
    GazeCalibration.swift           ridge-regression features → screen model, per-layout store
    OneEuroFilter.swift             gaze smoothing
    VisionGazeSource.swift          the webcam backend: camera → features → calibrated, filtered points
    GazeFocusController.swift       hold-look-release sessions, dwell, window hit-testing
    GazeCalibrationFlow.swift       full-screen calibration dots + live preview
    GazeHighlightPanel.swift        the frame drawn around the gazed-at window
Resources/Info.plist                app bundle metadata (menu-bar-only app, camera usage text)
Resources/Riffle.icns               app icon
Tools/GenerateIcon.swift            regenerates the app icon (see below)
build.sh                            compile + assemble + sign dist/Riffle.app
install.sh                          build + install to /Applications + launch
```

### Publishing a release (for maintainers)

The in-app updater reads the repo's **latest** GitHub release, compares its tag against the app's `CFBundleShortVersionString`, and downloads the release's `.zip` asset. To ship an update:

1. Bump the version in `Resources/Info.plist` (both `CFBundleShortVersionString` and `CFBundleVersion`), e.g. to `1.1`.
2. Build — this now also produces the release zip:

```bash
./build.sh
# → dist/Riffle.app  and  dist/Riffle-1.1.zip
```

3. Create a GitHub release whose **tag matches the version** and attach the zip as an asset:

```bash
gh release create v1.1 dist/Riffle-1.1.zip \
  --title "Riffle 1.1" \
  --notes "What changed in this release."
```

The updater strips a leading `v`, so tags like `v1.1` or `1.1` both work. The release notes (`body`) are shown in the update prompt. Any newer release that has **no `.zip` asset** falls back to just opening the release page.

### Regenerating the icon

The app icon is drawn programmatically. To change it, edit `Tools/GenerateIcon.swift`, then:

```bash
swift Tools/GenerateIcon.swift build/Riffle.iconset
iconutil -c icns build/Riffle.iconset -o Resources/Riffle.icns
rm -rf build/Riffle.iconset
```
