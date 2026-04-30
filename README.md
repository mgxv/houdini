```
  _                           _   _           _
 | |__     ___    _   _    __| | (_)  _ __   (_)
 | '_ \   / _ \  | | | |  / _` | | | | '_ \  | |
 | | | | | (_) | | |_| | | (_| | | | | | | | | |
 |_| |_|  \___/   \__,_|  \__,_| |_| |_| |_| |_|
```

# houdini

[![CI](https://github.com/mgxv/houdini/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mgxv/houdini/actions/workflows/ci.yml)
[![Homebrew](https://img.shields.io/github/v/tag/mgxv/houdini?logo=homebrew&label=brew&color=orange&sort=semver)](https://github.com/mgxv/homebrew-houdini)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A macOS background daemon that hides the menu bar when the frontmost fullscreen app is the same one playing in the system **Now Playing** widget — fullscreen YouTube, Netflix, Apple TV+, Spotify, etc. When you switch apps, exit fullscreen, or pause, the menu bar returns. No UI; one fallback hotkey (`⌃⌥⌘M`) for the rare cases where AX events stutter and the bar gets stuck.

## Who this is for

People who keep the menu bar visible by default but want it out of the way during fullscreen media playback.

macOS's native "Automatically hide and show the menu bar in full screen" pref is all-or-nothing — flip it on and the bar disappears from *every* fullscreen window, including Terminal, your editor, and Figma. houdini scopes the same behavior to "the frontmost fullscreen app is the one driving Now Playing":

- **Fullscreen YouTube / Netflix / Apple TV+ / Music / QuickTime** — bar hides while playing.
- **Fullscreen Terminal / VS Code / Figma / anything not driving Now Playing** — bar stays put.

Pause, switch apps, or exit fullscreen, and the bar comes back.

## How it works

houdini hides the menu bar only when **all** of these are true:

1. An app is in native fullscreen
2. That app is the frontmost (focused) app
3. That same app is actively playing media via Now Playing
4. The focused window's title contains the Now Playing track title — distinguishes between two windows of the same app, e.g. a playing FS Chrome tab vs. a different FS Chrome window.

When any becomes false, the menu bar comes back.

```
┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│    AppKit    │ │   Dock Log   │ │ MediaRemote  │ │  AXWatcher   │ │    Hotkey    │
│ (in-process) │ │ (subprocess) │ │ (Perl shim)  │ │ (in-process) │ │   (Carbon)   │
└──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
       │                │                │                │                │
       │ frontmost      │ FS state       │ playback       │ AX focus       │ ⌃⌥⌘M
       │ changed        │ + owner PID    │ state + PID    │ + title change │ pressed
       │                │ + FS↔FS hop    │ + bundle       │ notifications  │
       │                │   (refresh)    │ + track title  │                │
       ▼                ▼                ▼                ▼                ▼
   front_app    dock_fs / dock_stay   adapter           window           hotkey
       │                │                │                │                │
       └────────────────┴────────────────┼────────────────┴────────────────┘
                                         │
                                         ▼
                       ┌──────────────────────────────────────┐
                       │              Controller              │
                       │     + initial launch trigger (start) │
                       └──────────────────┬───────────────────┘
                                          ▼
                                    takeSnapshot()
                            (probes AX window title only when
                             FS + playing + both PIDs present)
                                          │
                                          ▼
                          menuBarDecision (sequential gates)
                          ─────────────────────────────────

                       (1) Fullscreen Space active?
                           └─ no  → show(not_fullscreen)

                       (2) Media playing?
                           └─ no  → show(not_playing)

                       (3) Frontmost PID present?
                           └─ no  → show(no_front_pid)

                       (4) Now Playing PID present?
                           └─ no  → show(no_now_playing_pid)

                       (5) Frontmost owns FS Space?
                           (multi-display gate)
                           └─ no  → show(front_not_fs_owner)

                       (6) Frontmost == Now Playing source?
                           (process or bundle match)
                           └─ no  → show(app_mismatch)

                       (7) Window title contains track title?
                           (AX-based refinement)
                           └─ no  → show(window_mismatch)

                                          │
                                          ▼
                                  effectiveShouldHide
                                (overrule: hotkey toggles
                                 force_hide / force_show;
                                 any other trigger → auto)
                                          │
                                          ▼
                  AppleMenuBarVisibleInFullscreen (system pref)
                  + DistributedNotification → WindowServer
```

<details>
<summary><strong>Internally</strong> — where each signal comes from</summary>

- **Fullscreen state and the FS owner's PID.** Dock's `dock-visibility` log channel, tapped by spawning `/usr/bin/log stream`. The predicate filters to two message shapes:
  - `Space Forces Hidden:` — emitted on FS entry/exit, carries the active Space's fullscreen flag and the FS app's PID.
  - `Skipping no-op state update` — emitted on FS↔FS Space switches where Dock's own visibility doesn't need to flip; a payload-less wake-up pulse that lets us refresh the cached FS owner from `NSWorkspace.frontmostApplication`. Without this, switching directly between two fullscreen apps would keep the menu bar in the wrong state.

  **Why FS detection isn't AX-based.** The obvious alternative — observing `kAXFullScreenAttribute` on the focused window — was tried and rejected. AX notifications flake during fullscreen animations, and a window's `AXFullScreen` attribute is set asynchronously by the app, sometimes hundreds of milliseconds after Dock declares the transition complete; querying AX right after a Space change produced false negatives, silently missing a meaningful fraction of FS toggles. AX also misses the notification entirely for FS transitions triggered via the green stoplight button or an in-page media-player FS toggle when the app first launches. Reading from Dock's log sidesteps the race because Dock emits at decision time, before any FS-aware app has finished animating. AX is opt-in here only for window-*title* refinement, where racing to read a stable string is far more forgiving than racing to detect a state edge — and where a missed read just falls through to the lenient hide default.
- **Frontmost app, bundle id, and responsibility-PID.** AppKit's `NSWorkspace.didActivateApplicationNotification` plus `NSWorkspace.frontmostApplication`; the responsibility-PID is read via the private `responsibility_get_pid_responsible_for_pid` syscall (declared via `@_silgen_name` in `Sources/PID.swift`) and resolves helper processes to their parent app (e.g. WebKit.GPU → Safari) so the same-app check works without adapter cooperation.
- **Now Playing — `playing` flag, owning PID, parent bundle, and track title.** The system MediaRemote framework, via the vendored `mediaremote-adapter` subprocess (perl is on Apple's MediaRemote allowlist; an unentitled Swift binary isn't). The adapter is run in `stream` mode with `--no-diff --debounce=200 --no-artwork`; each newline-delimited JSON event is decoded into a `NowPlayingSnapshot`.
- **Focused window's title (window-level refinement).** Accessibility, two paths working together:
  - An `AXObserver` subscribed to `kAXFocusedWindowChangedNotification`, `kAXFocusedUIElementChangedNotification`, and per-window `kAXTitleChangedNotification` (re-pointed each time the focused window changes). Each notification fires `evaluate(.window)` so within-app focus and title changes re-evaluate the decision.
  - On-demand window-title resolution at snapshot time: walk `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` in z-order, bridge each on-screen `CGWindowID` to its `AXUIElement` via the private `_AXUIElementGetWindow` SPI, and return the first non-empty `kAXTitleAttribute`. Z-order (rather than `kAXFocusedWindow`) is used because AX-focused window doesn't update on Space swipes, and because some apps (Chrome) put a titleless helper window ahead of the actual content window in fullscreen.

  When AX permission isn't granted the watcher is a no-op (logged once via `noteAXError`) and the daemon degrades to process-level matching only.

All signals are public APIs (`responsibility_get_pid_responsible_for_pid` and `_AXUIElementGetWindow` are private SPIs; the rest are public). No entitlements required.

</details>

**Hardware note.** Houdini is best on notched MacBooks (14"/16" MacBook Pro 2021+, 13"/15" MacBook Air 2022+).

- **Notched:** the menu-bar slot is permanently reserved for the notch, so toggling the fullscreen menu-bar preference doesn't change the window's content area — show/hide is purely visual.
- **Non-notched:** the fullscreen window resizes by the menu-bar height each time, which reflows in-window content (e.g. a web page in Chrome shifts up or down by the menu-bar height).

Functionally identical; only visually different.

## Install

```bash
# one-time setup
brew tap mgxv/houdini
brew install houdini

# or as a single command
brew install mgxv/houdini/houdini
```

Then start the service:

```bash
brew services start houdini
```

### Accessibility permission

The first start prompts for **Accessibility permission**. Granting it lets houdini distinguish between two windows of the same app — e.g. only hide the menu bar when the *playing* Chrome tab is fullscreen, not a different fullscreen Chrome window. Without permission, the daemon falls back to process-level matching only (it'll hide the bar for any FS Chrome window when audio is playing in any of them).

If you dismiss the prompt or revoke later, run `brew services restart houdini` to re-trigger it. After **`brew upgrade houdini`** you'll need to re-grant — macOS treats the freshly-signed binary as a new identity, so the existing AX grant no longer applies. Restart the service to re-prompt:

```bash
brew services restart houdini
```

## Usage

```bash
brew services start   houdini     # start and enable at login
brew services stop    houdini     # stop and disable
brew services restart houdini     # stop + start
brew services info    houdini     # state, PID, plist path
```

Running the binary directly (`./houdini`) is useful for debugging; `brew services` is the normal path.

## Manual override

`⌃⌥⌘M` (Ctrl+Option+Cmd+M) flips the menu bar yourself — force-hide if it's showing, force-show if it's hidden. The override is one-shot: the next time you switch apps, toggle fullscreen, switch tabs, or pause/resume playback, houdini takes over again automatically.

It's a fallback for the rare moments when macOS is slow to tell houdini about a focused window change, leaving the bar visible during a fullscreen video, or hidden when it shouldn't be. Press the shortcut to flip the bar; the next real event puts houdini back in charge.

## Diagnostics

<details>
<summary>Click to expand</summary>

```bash
houdini status                    # print version, daemon state,
                                  # adapter/dock-log subprocess health,
                                  # hotkey registration, and
                                  # Accessibility permission
houdini logs                      # stream every houdini unified-log entry
                                  # across all categories at debug level
                                  # (controller decisions, dock-visibility
                                  # events, mediaremote-adapter output,
                                  # startup notices); wraps
                                  # `log stream --predicate …`
houdini version                   # print version
houdini help                      # full usage
```

`houdini status` is the fastest way to confirm the install: which version is in your `$PATH`, whether a daemon currently holds the instance lock, whether the daemon's two subprocesses (`mediaremote-adapter` and the Dock-log `log stream`) are alive, whether the [Manual override](#manual-override) hotkey registered (`registered` / `failed` / `unknown` if the daemon hasn't recorded its state yet — usually means restart it), and whether Accessibility permission is granted (without it, the daemon falls back to process-level matching only). Exits non-zero if the daemon or either subprocess isn't running, so it composes in scripts. The hotkey and accessibility lines don't affect the exit code — both are graceful-degradation features. For the live decision (frontmost app, Now Playing, hide/show), watch `houdini logs`.

Everything goes to the macOS unified log under subsystem `com.github.mgxv.houdini`, organized into three categories:

- `controller` — hide/show snapshots (info), plus per-input breadcrumbs at debug:
  - `→ dock_rx fs=… pid=…` (parsed `Space Forces Hidden:` lines) and `→ dock_rx stay_space_change` (the FS↔FS hop pulse)
  - `→ front_rx pid=… bundle=… name=…` (each AppKit `didActivateApplicationNotification`)
  - `→ ax_rx name=… app=… pid=… window=…` (per AX focus / UI-element / title notification — useful for correlating a hide/show with the AX event that triggered it)
  - `→ eval_skipped trig=…` (snapshot equal to the previous one) and `→ eval_skipped_no_window trig=window` (AX-driven evaluation where the focused window's title came back nil — a transient AX state during normal interaction; suppressed so the menu bar doesn't flicker)
- `adapter` — `→ np_rx type=data play=… pid=… bundle=… parent=… title=…` per Now Playing event from mediaremote-adapter, plus subprocess stderr (debug)
- `general` — startup/shutdown notices, warnings (including the one-shot AX-permission notice from `noteAXError`), errors (info / error)

`houdini logs` streams everything across all three categories at debug level — no flags, one stream, ready to copy-paste into a bug report. The system handles retention and rotation; nothing on disk to manage.

```bash
houdini logs                                              # live stream — everything, debug level
log show --predicate 'subsystem == "com.github.mgxv.houdini"' --last 1h   # history
```

Or open Console.app, filter on subsystem `com.github.mgxv.houdini`, and toggle **Action → Include Debug Messages** / **Include Info Messages**.

</details>

## Troubleshooting

<details>
<summary>Click to expand</summary>

### The menu bar isn't hiding

Run `houdini logs` and exercise the trigger you expect to hide the bar (fullscreen the app, start playback). Each evaluation prints a hide/show snapshot with the inputs that drove it:

```
→ hide  trig=adapter overrule=auto appMatch=process front_tx=Safari[pid=501,name="Safari",bundle=com.apple.Safari,resp=null,fs=yes,fsPid=501,win="BLACKPINK - 'GO' M/V - YouTube",probe=ok]
→ np_tx=WebKit.GPU[pid=506,bundle=com.apple.WebKit.GPU,parent=com.apple.Safari,resp=501,play=yes,title="BLACKPINK - 'GO' M/V"]
```

The leading verb is `→ hide` or `→ show(reason)`, where reason names the first guard that tripped — one of `not_fullscreen`, `not_playing`, `no_front_pid`, `no_now_playing_pid`, `front_not_fs_owner`, `app_mismatch`, or `window_mismatch`. `trig=` names the input that fired this evaluation: `start`, `front_app`, `dock_fs`, `dock_stay`, `adapter`, `window` (an AX focus/title event), or `hotkey` (manual override). `overrule=` is `auto` (daemon-driven), `force_hide`, or `force_show` (the hotkey's one-shot override is in effect). `appMatch=` is `process`, `bundle`, `both`, or `none` — which gate-6 path matched. `resp=` on each side is the kernel's responsibility-resolved root PID (`null` for top-level apps, a PID for helper processes like WebKit.GPU resolving to Safari) — what the same-app process check actually compares. `win=` is the focused window's AX title; `title=` on the np line is the Now Playing track title — the window-level refinement does a substring match between them. `probe=` records why the AX window-title probe ended up where it did: `ok` (got a title), `skipped` (an earlier gate short-circuited), `denied` (Accessibility not granted), `ax_failed` (AX returned an unexpected error — see `houdini logs` for the specific code), or `empty` (no matching on-screen window or title was empty).

Each input also leaves a debug breadcrumb at the boundary, so a wrong decision can be traced back to the data that drove it: `→ np_rx …` per Now Playing event from mediaremote-adapter, `→ front_rx …` when AppKit reports a new frontmost app, `→ dock_rx …` per parsed Dock event, `→ ax_rx …` per AX focus/title notification, and `→ eval_skipped trig=…` / `→ eval_skipped_no_window trig=…` when the evaluation produced no change.

Hide requires all of: `fs=yes`, the frontmost `pid` matching `fsPid`, `play=yes`, frontmost/Now-Playing resolving to the same app (process or bundle match), and — when both sides have a title — the window title containing the track title. Common reasons a show is logged when you expected hide:

- **`fs=no`** (`show(not_fullscreen)`) — Dock has not reported a fullscreen Space transition. Native fullscreen (⌃⌘F, the green-stoplight button, or in-page fullscreen buttons in YouTube, Netflix, QuickTime) creates a dedicated Space; merely-maximized windows that just fill the screen don't qualify.
- **`play=no`** (`show(not_playing)`) — the Now Playing source is paused; play/pause state comes directly from the media app.
- **front `pid=null`** (`show(no_front_pid)`) — defensive; AppKit reported no frontmost application. Rare in practice (some kinds of Lock-Screen / login-window state).
- **`np_tx=[pid=null,...]`** (`show(no_now_playing_pid)`) — nothing is using Now Playing. Some players (e.g. a browser tab playing inline video with no media-session metadata) never register with the system Now Playing widget.
- **`fs=yes` but `pid ≠ fsPid`** (`show(front_not_fs_owner)`) — a fullscreen Space exists, but the frontmost app isn't its owner. Typically you've Cmd-Tab'd to a different app whose window is now in front; the menu bar belongs to the frontmost app, not to the (still-fullscreen) Space underneath.
- **front bundle ≠ np parent and `resp` doesn't match the frontmost pid** (`show(app_mismatch)`) — e.g. Spotify is playing in the background while Safari is the focused fullscreen app.
- **`win="…"` doesn't contain `title="…"`** (`show(window_mismatch)`) — same-app match passed, but the focused window's title doesn't reflect the playing track. Two FS Chrome windows on different displays, only one playing music: only the playing one gets the bar hidden. Without Accessibility permission (`probe=denied`) the check falls through to hide — the daemon can't distinguish window-level cases. `probe=ax_failed` instead means AX is misbehaving for this app right now; check `houdini logs` for the specific AX error code. If a delayed or missed AX title event has left this gate stuck on the wrong window, press `⌃⌥⌘M` to flip the bar (see [Manual override](#manual-override)); the next real event yields control back to the daemon.

### Is it actually running?

`houdini status` prints daemon, adapter, dock-log, hotkey, and Accessibility state in one go and exits non-zero if the daemon or either subprocess isn't running. If either subprocess dies unexpectedly, the daemon emits an error to the unified log (see `houdini logs`) and exits; launchd then relaunches it via `brew services`.

### Starting clean

To clear orphan subprocesses or a foreground `./houdini` you forgot about:

```bash
brew services stop houdini
pkill -x houdini
pkill -f mediaremote-adapter
brew services start houdini
```

</details>

## Project layout

```
scripts/              # Build and release scripts
  build.sh            # Builds the framework + Swift binary (canonical path)
  release.sh          # Version bump → tag → formula update → tap mirror
Formula/houdini.rb    # Homebrew formula
Package.swift         # Optional SwiftPM manifest (for IDE indexing)
Sources/              # Swift daemon + CLI (Swift 6, strict concurrency)
Sources/Version.swift # Single source of truth for the version string
MIN_MACOS             # Single source of truth for the macOS deployment floor
                      #   (read by build.sh + Package.swift; release.sh
                      #   validates; Formula/houdini.rb is hand-maintained)
vendor/               # mediaremote-adapter (Obj-C + Perl shim)
```

## Acknowledgements

houdini is built on top of [**mediaremote-adapter**](https://github.com/ungive/mediaremote-adapter) by [Jonas van den Berg (@ungive)](https://github.com/ungive). Without it, there would be no practical way for an unentitled binary to observe Now Playing state on modern macOS. Huge thanks to Jonas and the project's contributors.

The vendored sources under `vendor/mediaremote-adapter/` are distributed under the BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).

## License

houdini is released under the MIT License. See [`LICENSE`](./LICENSE) for the full text.

The vendored `mediaremote-adapter` retains its own BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).
