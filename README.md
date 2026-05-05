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

A macOS background daemon that hides the menu bar when the frontmost fullscreen app is the same one playing in the system **Now Playing** widget — fullscreen YouTube, Netflix, Apple TV+, Spotify, etc. Pause, switch apps, or exit fullscreen and the bar comes back.

No UI. One fallback hotkey (`⌃⌥⌘M`) for the rare cases where AX events stutter and the bar gets stuck.

## Who this is for

People who keep the menu bar visible by default but want it out of the way during fullscreen media playback.

macOS's native "Automatically hide and show the menu bar in full screen" pref is all-or-nothing — flip it on and the bar disappears from *every* fullscreen window, including Terminal, your editor, and Figma. houdini scopes that behavior to "the frontmost fullscreen app is the one driving Now Playing":

- **Hides** in fullscreen YouTube / Netflix / Apple TV+ / Music / QuickTime while playing.
- **Stays put** in fullscreen Terminal, editors, Figma — anything not driving Now Playing.

Pause, switch apps, or exit fullscreen, and the bar comes back.

## Modes

Set with `houdini mode <smart|fixed>`, then `brew services restart houdini` to apply. Default is `smart`. Current mode shows in `houdini status`.

  <details><summary><strong>Smart</strong> — automatic, signal-driven (default)</summary>

  Hides the menu bar only when **all** of these are true:

  1. An app is in native fullscreen.
  2. That app is the frontmost (focused) app.
  3. That same app is actively playing media via Now Playing.
  4. The focused window's title contains the Now Playing track title (or vice versa). Distinguishes between two windows of the same app — e.g. a playing FS Chrome tab vs. a different FS Chrome window. The reverse direction handles native players whose window title is a shorter form of the NP string.

  When any becomes false, the menu bar comes back. The hotkey overrules per-tab — see [Hotkey](#hotkey). For signal sources and the gate-by-gate diagram, see [Architecture](#architecture).

  </details>

  <details><summary><strong>Fixed</strong> — manual hotkey toggle</summary>

  No automatic logic. The menu bar is visible by default; pressing the hotkey hides it, pressing again shows it.

  Useful when:
  - You want full manual control over fullscreen menu-bar visibility.
  - You don't want to grant Accessibility, and process-level matching isn't enough.
  - Now Playing isn't reliable for the apps you use.

  No Dock log, no AX, no Now Playing subprocess — just the hotkey. Toggle state isn't persisted across daemon restart; the bar starts visible.

  </details>

## Hardware note

houdini is best on notched MacBooks (14"/16" MacBook Pro 2021+, 13"/15" MacBook Air 2022+).

- **Notched** — the menu-bar slot is permanently reserved for the notch, so toggling fullscreen menu-bar visibility doesn't change the window's content area. Show/hide is purely visual.
- **Non-notched** — the fullscreen window resizes by the menu-bar height each time, which reflows in-window content (e.g. a Chrome page shifts up or down).

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

Granting Accessibility lets houdini distinguish between two windows of the same app — e.g. only hide the bar when the *playing* Chrome tab is fullscreen, not a different fullscreen Chrome window.

- **Granted** — full window-level differentiation.
- **Not granted** — process-level matching only (hides the bar for any FS Chrome window when audio is playing in any of them).

To grant, open System Settings → Privacy & Security → Accessibility, enable houdini, then restart the service:

```bash
brew services restart houdini
```

After `brew upgrade houdini` you'll need to re-grant — macOS treats the freshly-signed binary as a new identity, so the existing grant no longer applies.

## Usage

```bash
brew services start   houdini     # start and enable at login
brew services stop    houdini     # stop and disable
brew services restart houdini     # stop + start
brew services info    houdini     # state, PID, plist path

houdini mode smart|fixed          # set mode (restart to apply); current mode shows in `houdini status`
```

Running the binary directly (`./houdini`) is useful for debugging; `brew services` is the normal path.

## Hotkey

`⌃⌥⌘M` (Ctrl+Option+Cmd+M). Behavior depends on the active [mode](#modes).

**In smart mode** — overrules the daemon's automatic decision for the current tab/window:

- **Sticky to the tab/window** where you set it. Pinned on `(bundle id, focused window title, Now Playing title)`.
- **Survives** pause/resume, AX title wobble, FS↔FS hops, and switching to other apps.
- **Matches via window title or Now Playing title** under the same bundle. Players that roll the window title per episode but keep the show name in NP carry the pin across episodes.
- **Doesn't apply on a different tab/window** — the daemon's auto decision wins there. Coming back to the original re-applies it without another press.
- **Press again on the same tab** to flip the pin to the opposite direction. Re-pinning under the same context replaces the prior entry, so contradictory pins don't accumulate.
- **In-memory only** — cleared on daemon restart.

When the focused window has no AX title (Accessibility not granted, or a login-window-style edge), the press becomes a one-shot fallback that clears on the next real event.

It's a fallback for the rare moments when macOS is slow to tell houdini about a focused window change, leaving the bar visible during a fullscreen video, or hidden when it shouldn't be.

**In fixed mode** — plain toggle: press hides, press again shows. No per-tab pinning, no daemon-driven decisions to overrule. If the hotkey doesn't toggle, check `houdini status` — the `hotkey:` field should read `registered`.

## Smart mode internals

How smart mode works under the hood, how to inspect it, and how to debug it. Fixed mode bypasses all of this — `houdini status` is mode-aware, but the gate semantics, signal pipeline, and log breadcrumbs below are smart-only.

### Troubleshooting

<details>
<summary>Click to expand</summary>

#### The menu bar isn't hiding

Run `houdini logs` and exercise the trigger you expect to hide the bar (fullscreen the app, start playback). Each evaluation prints a snapshot:

```
→ hide  trig=adapter overrule=auto appMatch=process front_tx=Safari[pid=501,name="Safari",bundle=com.apple.Safari,resp=null,fs=yes,fsPid=501,win="BLACKPINK - 'GO' M/V - YouTube",probe=ok,dockWin="BLACKPINK - 'GO' M/V - YouTube"]
→ np_tx=WebKit.GPU[pid=506,bundle=com.apple.WebKit.GPU,parent=com.apple.Safari,resp=501,play=yes,title="BLACKPINK - 'GO' M/V"]
```

Field reference:

- **`→ hide` / `→ show(reason)`** — first guard that tripped: `not_fullscreen`, `not_playing`, `no_front_pid`, `no_now_playing_pid`, `front_not_fs_owner`, `app_mismatch`, `window_mismatch`.
- **`trig=`** — input that fired this evaluation: `start`, `front_app`, `dock_fs`, `dock_stay`, `adapter`, `window` (an AX focus/title event), `hotkey`.
- **`overrule=`** — `auto` (daemon-driven), or `force_hide` / `force_show` followed by `(sticky)` (per-tab pinned via the hotkey, in `overrideMap`) or `(global)` (no-key fallback used when AX or window title isn't available; auto-clears on the next signal change).
- **`appMatch=`** — `process`, `bundle`, `both`, `none`, or `n/a` (when a PID is missing) — which gate-6 path matched.
- **`resp=`** — kernel's responsibility-resolved root PID; `null` for top-level apps, a PID for helpers (WebKit.GPU resolving to Safari). What the same-app process check actually compares.
- **`win=`** — focused window's AX title; **`title=`** on the np line is the Now Playing track title.
- **`dockWin=`** — Dock's tile-name field captured at FS edge from the `Space Forces Hidden:` line. Used as gate 7 input on `dock_fs` / `dock_stay` triggers when AX hasn't yet populated; `null` on FS-exit and on stay pulses where the FS app changed.
- **`probe=`** — why the AX window-title probe ended up where it did:
  - `ok` — got a title.
  - `skipped` — an earlier gate short-circuited.
  - `denied` — Accessibility not granted.
  - `ax_failed` — AX returned an unexpected error (see `houdini logs` for the code).
  - `empty` — no matching on-screen window or all titles were empty.

Each input also leaves a debug breadcrumb at the boundary — `→ np_rx`, `→ front_rx`, `→ dock_rx`, `→ ax_rx`, `→ eval_skipped`, `→ eval_skipped_no_window` — so a wrong decision can be traced back to the data that drove it.

##### Common reasons a `show` is logged when you expected `hide`

- **`fs=no`** (`show(not_fullscreen)`) — Dock has not reported a fullscreen Space transition. Native fullscreen (⌃⌘F, the green-stoplight button, or in-page fullscreen buttons) creates a dedicated Space; merely-maximized windows that just fill the screen don't qualify.
- **`play=no`** (`show(not_playing)`) — the Now Playing source is paused; play/pause state comes directly from the media app.
- **front `pid=null`** (`show(no_front_pid)`) — defensive; AppKit reported no frontmost application. Rare in practice (some Lock-Screen / login-window states).
- **`np_tx=[pid=null,…]`** (`show(no_now_playing_pid)`) — nothing is using Now Playing. Some players (browser tabs without media-session metadata) never register with the system widget.
- **`fs=yes` but `pid ≠ fsPid`** (`show(front_not_fs_owner)`) — a fullscreen Space exists, but the frontmost app isn't its owner. Typically you've Cmd-Tabbed to a different app.
- **front bundle ≠ np parent and `resp` doesn't match the front pid** (`show(app_mismatch)`) — e.g. Spotify is playing in the background while Safari is the focused fullscreen app.
- **`win` doesn't overlap `title`** (`show(window_mismatch)`) — same-app match passed, but the focused window's title and the NP track share no substring in either direction. Two FS Chrome windows on different displays, only one playing music: only the playing one gets the bar hidden. With AX denied (`probe=denied`) the check falls through to lenient hide; with AX granted, a real mismatch surfaces. If a delayed AX event has stuck this gate on the wrong window, press `⌃⌥⌘M` (see [Hotkey](#hotkey)). For services that intentionally keep these two strings disjoint, see [HBO Max and episode-only window titles](#hbo-max-and-episode-only-window-titles) below.

#### Is it actually running?

`houdini status` prints version, mode, daemon, adapter, dock-log, hotkey, and Accessibility state in one go and exits non-zero if a load-bearing component for the active mode is missing. If a subprocess dies unexpectedly, the daemon emits an error to the unified log (see `houdini logs`) and exits; launchd then relaunches it via `brew services`.

#### Starting clean

Clear orphan subprocesses or a foreground `./houdini` you forgot about:

```bash
brew services stop houdini
pkill -x houdini
pkill -f mediaremote-adapter
brew services start houdini
```

#### HBO Max and episode-only window titles

A few streaming services put only the *episode* name in the browser's window title and only the *show* name in Now Playing. HBO Max is the canonical case:

```
win   = "1:23:45 • HBO Max - Google Chrome - <user>"
title = "Chernobyl"
```

Neither string contains the other in either direction, so gate 7 fires `show(window_mismatch)` every time the daemon is asked, and the menu bar stays visible the whole way through the episode.

Counter-intuitively this means **granting Accessibility actually keeps the bar visible for these services**. Without Accessibility, gate 7 has no window title to compare against (`probe=denied`) and falls through to lenient hide; with Accessibility, it sees a real mismatch and refuses. There's no daemon-side fix — the two strings simply don't share enough information to align.

The escape hatch is the [hotkey](#hotkey): press `⌃⌥⌘M` once on the playing tab to pin the bar hidden. The pin survives pause, AX title wobble, FS↔FS hops, and the `Audio playing` annotation Chrome adds while audio is active. But because HBO Max rewrites the window title from one episode title to the next without keeping the show name visible, the pin's NP-axis fallback can't anchor across episodes either — press `⌃⌥⌘M` again at each episode change to re-pin. Or switch to [fixed mode](#modes), where the hotkey is a plain toggle and isn't bound to window-title state.

#### Safari element-level fullscreen video

Affects the **in-page video fullscreen button** (the YouTube / Netflix / Apple-TV+ FS button) when **Safari itself is not already fullscreen**. Window-level fullscreen of the whole Safari window (⌃⌘F or the green stoplight) is unaffected — the FS Space is the Safari browser-chrome window with the page title preserved, so probing and Dock both succeed.

In the affected path, Safari hosts the element-fullscreen surface in a helper process (`WebKit.WebContent` / `WebKit.GPU`). The visible FS window's `kCGWindowOwnerPID` belongs to that helper, and Safari's main process exposes no AX child for it — so houdini's window-title probe (which walks `CGWindowListCopyWindowInfo` filtered to the front app's PID) finds no candidate and returns `probe=empty`. Dock's tile log compounds it: with no usable title from Safari's main process, Dock falls back to writing `name=Safari` (its `appName` fallback) into the `Space Forces Hidden:` line. Gate 7 then has nothing real to substring-match against the Now Playing track:

```
show(window_mismatch)  trig=dock_fs …,probe=empty,dockWin=Safari
np_tx=WebKit.GPU[…,parent=com.apple.Safari,…,play=yes,title="<video title>"]
```

Chrome / Brave / Edge aren't affected by either path — they host element-FS video in the main browser-chrome window with the page title preserved.

Workarounds:

- **Fullscreen the Safari window first** (⌃⌘F or green stoplight), *then* play the video inline. Avoids the helper-owned surface entirely.
- Press `⌃⌥⌘M` on the playing tab to pin the bar hidden.
- Switch to [fixed mode](#modes), where the hotkey is a plain toggle.

</details>

### Diagnostics

<details>
<summary>Click to expand</summary>

```bash
houdini status      # version, mode, daemon state, subprocess health
                    # (smart mode), hotkey registration, Accessibility
houdini logs        # stream every houdini unified-log entry at debug level
houdini version     # print version
houdini help        # full usage
```

`houdini status` is the fastest way to confirm the install. It checks:

- Which `houdini` is in your `$PATH` (version).
- The active [mode](#modes) (`smart` or `fixed`).
- Whether a daemon currently holds the instance lock.
- Whether the two subprocesses (`mediaremote-adapter`, the Dock-log `log stream`) are alive — smart mode only; fixed mode prints `n/a (fixed mode)`.
- Whether the [hotkey](#hotkey) registered (`registered` / `failed` / `unknown`).
- Whether Accessibility is granted.

Exit code is non-zero if a load-bearing component is missing for the active mode: in smart mode, the daemon and both subprocesses must be running; in fixed mode, the daemon must be running with the hotkey registered. Accessibility is informational in both modes.

For the live decision (frontmost app, Now Playing, hide/show), watch `houdini logs`.

#### Unified log

Subsystem `com.github.mgxv.houdini`, three categories:

- **`controller`** — hide/show snapshots (info), per-input breadcrumbs (debug):
  - `→ dock_rx fs=… pid=…` — parsed `Space Forces Hidden:` lines.
  - `→ dock_rx stay_space_change` — the FS↔FS hop pulse.
  - `→ front_rx pid=… bundle=… name=…` — AppKit `didActivateApplicationNotification`.
  - `→ ax_rx name=… app=… pid=… window=…` — per AX focus / UI-element / title notification.
  - `→ eval_skipped trig=…` — snapshot equal to the previous one.
  - `→ eval_skipped_no_window trig=window` — AX-driven evaluation with a transient nil window title; suppressed so the bar doesn't flicker on every keystroke.
- **`adapter`** — `→ np_rx type=data play=… pid=… bundle=… parent=… title=…` per Now Playing event from mediaremote-adapter, plus subprocess stderr (debug).
- **`general`** — startup/shutdown notices, warnings (one-shot AX-permission notice from `noteAXError`), errors (info / error).

In fixed mode only `controller` (hide/show via hotkey) and `general` (startup/shutdown) emit; the `adapter` category is silent because the subprocess isn't started.

`houdini logs` streams all three categories at debug level — no flags, one stream, ready to paste into a bug report:

```bash
houdini logs                                                              # live
log show --predicate 'subsystem == "com.github.mgxv.houdini"' --last 1h   # history
```

Or open Console.app, filter on subsystem `com.github.mgxv.houdini`, and toggle **Action → Include Debug Messages** / **Include Info Messages**.

</details>

### Architecture

<details>
<summary>Click to expand</summary>

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
                       │            SmartController           │
                       │     + initial launch trigger (start) │
                       └──────────────────┬───────────────────┘
                                          ▼
                                    takeSnapshot()
                            (probes AX window title whenever
                             a fullscreen Space has a frontmost
                             PID; gate 1 still avoids the probe
                             outside FS)
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

                       (7) Window title and track title overlap?
                           (AX-based; either-direction substring)
                           └─ no  → show(window_mismatch)

                                          │
                                          ▼
                                effectiveShouldHide
                             (overrule: hotkey pins
                             force_hide / force_show
                             per (bundle, window title,
                             NP title); matches via window
                             OR NP title — handles per-
                             episode window-title rolls;
                             sticky across pause, FS hops,
                             app switches; auto otherwise)
                                          │
                                          ▼
                  AppleMenuBarVisibleInFullscreen (system pref)
                  + DistributedNotification → WindowServer
```

<details>
<summary><strong>Internally</strong> — where each signal comes from</summary>

**Fullscreen state and FS-owner PID — Dock's `dock-visibility` log channel.** Spawned via `/usr/bin/log stream` with a predicate that filters to:

- `Space Forces Hidden:` — emitted on FS entry/exit; carries the active Space's fullscreen flag and owner PID.
- `Skipping no-op state update` — emitted on FS↔FS Space switches; payload-less wake-up that lets us refresh the cached owner from `NSWorkspace.frontmostApplication`.

Why not AX for FS state: AX notifications flake during FS animations and `kAXFullScreenAttribute` is set asynchronously by the app — sometimes hundreds of milliseconds after Dock has declared the transition complete. AX also misses some FS triggers entirely (green-stoplight, in-page media-player buttons). Dock emits at decision time. AX is opt-in here only for window-*title* refinement — racing to read a stable string is far more forgiving than racing to detect a state edge.

**Frontmost app and responsibility-PID — AppKit + private SPI.**

- `NSWorkspace.didActivateApplicationNotification` and `NSWorkspace.frontmostApplication`.
- `responsibility_get_pid_responsible_for_pid` (declared via `@_silgen_name` in `Sources/PID.swift`) resolves helper processes to their parent app — e.g. `WebKit.GPU` → Safari — so the same-app check works without adapter cooperation.

**Now Playing — vendored `mediaremote-adapter` subprocess.**

- perl is on Apple's MediaRemote allowlist; an unentitled Swift binary isn't. The adapter is a perl shim that loads `MediaRemoteAdapter.framework` via `dl_load_file`.
- Run in `stream` mode with `--no-diff --debounce=200 --no-artwork`; each newline-delimited JSON event decodes into a `NowPlayingSnapshot` (playing flag, owning PID, parent bundle, track title).

**Focused window title — Accessibility, two paths.**

- An `AXObserver` subscribed to `kAXFocusedWindowChangedNotification`, `kAXFocusedUIElementChangedNotification`, and per-window `kAXTitleChangedNotification` (re-pointed each time the focused window changes). Fires `evaluate(.window)` on every focus or title change.
- On-demand title resolution at snapshot time: walk `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])` in z-order, bridge each `CGWindowID` to its `AXUIElement` via the private `_AXUIElementGetWindow` SPI, return the first non-empty `kAXTitleAttribute`. Z-order rather than `kAXFocusedWindow` because the latter doesn't track Space swipes and Chrome puts a titleless helper window ahead of the actual content in fullscreen.
- When AX permission isn't granted the watcher is a no-op (logged once via `noteAXError`) and the daemon degrades to process-level matching only.

No entitlements required. Two private SPIs (`responsibility_get_pid_responsible_for_pid`, `_AXUIElementGetWindow`); everything else is public API.

</details>

</details>

## Acknowledgements

houdini is built on top of [**mediaremote-adapter**](https://github.com/ungive/mediaremote-adapter) by [Jonas van den Berg (@ungive)](https://github.com/ungive). Without it, there would be no practical way for an unentitled binary to observe Now Playing state on modern macOS. Huge thanks to Jonas and the project's contributors.

The vendored sources under `vendor/mediaremote-adapter/` are distributed under the BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).

## License

houdini is released under the MIT License. See [`LICENSE`](./LICENSE) for the full text.

The vendored `mediaremote-adapter` retains its own BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).
