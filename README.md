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

No UI. One fallback hotkey (`⌃⌥⌘M`) for the rare cases where the bar gets stuck.

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

  When any becomes false, the menu bar comes back. The hotkey overrules the daemon's decision until the next signal change — see [Hotkey](#hotkey). For signal sources and the gate-by-gate diagram, see [Architecture](#architecture).

  </details>

  <details><summary><strong>Fixed</strong> — manual hotkey toggle</summary>

  No automatic logic. The menu bar is visible by default; pressing the hotkey hides it, pressing again shows it.

  Useful when:
  - You want full manual control over fullscreen menu-bar visibility.
  - Now Playing isn't reliable for the apps you use.

  No Dock log, no Now Playing subprocess — just the hotkey. Toggle state isn't persisted across daemon restart; the bar starts visible.

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

**In smart mode** — flips the bar against the daemon's current decision and pins that choice until the next real signal change (front-app switch, fullscreen transition, play/pause, etc.), at which point the daemon resumes automatic control. Press again to flip back. Useful for the rare moments when macOS is slow to tell houdini about a state change.

**In fixed mode** — plain toggle: press hides, press again shows. If the hotkey doesn't toggle, check `houdini status` — the `hotkey:` field should read `registered`.

## Smart mode internals

How smart mode works under the hood, how to inspect it, and how to debug it. Fixed mode bypasses all of this — `houdini status` is mode-aware, but the gate semantics, signal pipeline, and log breadcrumbs below are smart-only.

### Troubleshooting

<details>
<summary>Click to expand</summary>

#### The menu bar isn't hiding

Run `houdini logs` and exercise the trigger you expect to hide the bar (fullscreen the app, start playback). Each evaluation prints a snapshot:

```
→ hide  trig=adapter overrule=auto appMatch=process front_tx=Safari[pid=501,name="Safari",bundle=com.apple.Safari,resp=null,fs=yes,fsPid=501]
→ np_tx=WebKit.GPU[pid=506,bundle=com.apple.WebKit.GPU,parent=com.apple.Safari,resp=501,play=yes,title="BLACKPINK - 'GO' M/V"]
```

Field reference:

- **`→ hide` / `→ show(reason)`** — first guard that tripped: `not_fullscreen`, `not_playing`, `no_front_pid`, `no_now_playing_pid`, `front_not_fs_owner`, `app_mismatch`.
- **`trig=`** — input that fired this evaluation: `start`, `front_app`, `dock_fs`, `dock_stay`, `adapter`, `hotkey`.
- **`overrule=`** — `auto` (daemon-driven), `force_hide`, or `force_show` (hotkey-pinned; auto-clears on the next signal change).
- **`appMatch=`** — `process`, `bundle`, `both`, `none`, or `n/a` (when a PID is missing) — which gate-6 path matched.
- **`resp=`** — kernel's responsibility-resolved root PID; `null` for top-level apps, a PID for helpers (WebKit.GPU resolving to Safari). What the same-app process check actually compares.
- **`title=`** on the np line is the Now Playing track title (diagnostic only — not a decision input).

Each input also leaves a debug breadcrumb at the boundary — `→ np_rx`, `→ front_rx`, `→ dock_rx`, `→ eval_skipped` — so a wrong decision can be traced back to the data that drove it.

##### Common reasons a `show` is logged when you expected `hide`

- **`fs=no`** (`show(not_fullscreen)`) — Dock has not reported a fullscreen Space transition. Native fullscreen (⌃⌘F, the green-stoplight button, or in-page fullscreen buttons) creates a dedicated Space; merely-maximized windows that just fill the screen don't qualify.
- **`play=no`** (`show(not_playing)`) — the Now Playing source is paused; play/pause state comes directly from the media app.
- **front `pid=null`** (`show(no_front_pid)`) — defensive; AppKit reported no frontmost application. Rare in practice (some Lock-Screen / login-window states).
- **`np_tx=[pid=null,…]`** (`show(no_now_playing_pid)`) — nothing is using Now Playing. Some players (browser tabs without media-session metadata) never register with the system widget.
- **`fs=yes` but `pid ≠ fsPid`** (`show(front_not_fs_owner)`) — a fullscreen Space exists, but the frontmost app isn't its owner. Typically you've Cmd-Tabbed to a different app.
- **front bundle ≠ np parent and `resp` doesn't match the front pid** (`show(app_mismatch)`) — e.g. Spotify is playing in the background while Safari is the focused fullscreen app.

#### Is it actually running?

`houdini status` prints version, mode, daemon, adapter, dock-log, and hotkey state in one go and exits non-zero if a load-bearing component for the active mode is missing. If a subprocess dies unexpectedly, the daemon emits an error to the unified log (see `houdini logs`) and exits; launchd then relaunches it via `brew services`.

#### Starting clean

Clear orphan subprocesses or a foreground `./houdini` you forgot about:

```bash
brew services stop houdini
pkill -x houdini
pkill -f mediaremote-adapter
brew services start houdini
```

</details>

### Diagnostics

<details>
<summary>Click to expand</summary>

```bash
houdini status      # version, mode, daemon state, subprocess health
                    # (smart mode), hotkey registration
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

Exit code is non-zero if a load-bearing component is missing for the active mode: in smart mode, the daemon and both subprocesses must be running; in fixed mode, the daemon must be running with the hotkey registered.

For the live decision (frontmost app, Now Playing, hide/show), watch `houdini logs`.

#### Unified log

Subsystem `com.github.mgxv.houdini`, three categories:

- **`controller`** — hide/show snapshots (info), per-input breadcrumbs (debug):
  - `→ dock_rx fs=… pid=…` — parsed `Space Forces Hidden:` lines.
  - `→ dock_rx stay_space_change` — the FS↔FS hop pulse.
  - `→ front_rx pid=… bundle=… name=…` — AppKit `didActivateApplicationNotification`.
  - `→ eval_skipped trig=…` — snapshot equal to the previous one.
- **`adapter`** — `→ np_rx type=data play=… pid=… bundle=… parent=… title=…` per Now Playing event from mediaremote-adapter, plus subprocess stderr (debug).
- **`general`** — startup/shutdown notices, warnings, errors (info / error).

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
┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│    AppKit    │ │   Dock Log   │ │ MediaRemote  │ │    Hotkey    │
│ (in-process) │ │ (subprocess) │ │ (Perl shim)  │ │   (Carbon)   │
└──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
       │                │                │                │
       │ frontmost      │ FS state       │ playback       │ ⌃⌥⌘M
       │ changed        │ + owner PID    │ state + PID    │ pressed
       │                │ + FS↔FS hop    │ + bundle       │
       │                │   (refresh)    │                │
       ▼                ▼                ▼                ▼
   front_app    dock_fs / dock_stay   adapter           hotkey
       │                │                │                │
       └────────────────┴────────────────┴────────────────┘
                                │
                                ▼
                ┌──────────────────────────────────────┐
                │            SmartController           │
                │     + initial launch trigger (start) │
                └──────────────────┬───────────────────┘
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

                                   │
                                   ▼
                         effectiveShouldHide
                      (overrule: hotkey pins
                      force_hide / force_show
                      until next signal change;
                      auto otherwise)
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

**Frontmost app and responsibility-PID — AppKit + private SPI.**

- `NSWorkspace.didActivateApplicationNotification` and `NSWorkspace.frontmostApplication`.
- `responsibility_get_pid_responsible_for_pid` (declared via `@_silgen_name` in `Sources/PID.swift`) resolves helper processes to their parent app — e.g. `WebKit.GPU` → Safari — so the same-app check works without adapter cooperation.

**Now Playing — vendored `mediaremote-adapter` subprocess.**

- perl is on Apple's MediaRemote allowlist; an unentitled Swift binary isn't. The adapter is a perl shim that loads `MediaRemoteAdapter.framework` via `dl_load_file`.
- Run in `stream` mode with `--no-diff --debounce=200 --no-artwork`; each newline-delimited JSON event decodes into a `NowPlayingSnapshot` (playing flag, owning PID, parent bundle, track title).

No entitlements required. One private SPI (`responsibility_get_pid_responsible_for_pid`); everything else is public API.

</details>

</details>

## Acknowledgements

houdini is built on top of [**mediaremote-adapter**](https://github.com/ungive/mediaremote-adapter) by [Jonas van den Berg (@ungive)](https://github.com/ungive). Without it, there would be no practical way for an unentitled binary to observe Now Playing state on modern macOS. Huge thanks to Jonas and the project's contributors.

The vendored sources under `vendor/mediaremote-adapter/` are distributed under the BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).

## License

houdini is released under the MIT License. See [`LICENSE`](./LICENSE) for the full text.

The vendored `mediaremote-adapter` retains its own BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).
