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

A macOS background daemon that hides the menu bar when the frontmost fullscreen app is the same one playing in the system **Now Playing** widget — fullscreen YouTube, Netflix, Apple TV+, Spotify, etc. When you switch apps, exit fullscreen, or pause, the menu bar returns. No UI, no hotkeys.

## Who this is for

People who keep the menu bar visible by default but want it out of the way during fullscreen media playback.

macOS's native "Automatically hide and show the menu bar in full screen" pref is all-or-nothing — flip it on and the bar disappears from *every* fullscreen window, including Terminal, your editor, and Figma. houdini scopes the same behavior to "the frontmost fullscreen app is the one driving Now Playing":

- **Fullscreen YouTube / Netflix / Apple TV+ / Music / QuickTime** — bar hides while playing.
- **Fullscreen Terminal / VS Code / Figma / anything not driving Now Playing** — bar stays put.

Pause, switch apps, or exit fullscreen, and the bar comes back.

## How it works

houdini hides the menu bar only when **all three** are true:

1. An app is in native fullscreen
2. That app is the frontmost (focused) app
3. That same app is actively playing media via Now Playing

When any one becomes false, the menu bar comes back.

```
   ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
   │  AppKit          │    │  Dock log        │    │  MediaRemote     │
   │  (in-process)    │    │  (subprocess)    │    │  (perl shim)     │
   └────────┬─────────┘    └────────┬─────────┘    └────────┬─────────┘
            │                       │                       │
       frontmost              fs=true|false              isPlaying,
       changed                + fs↔fs pulse              owning pid
            │                       │                       │
            └───────────────────────┼───────────────────────┘
                                    ▼
                            ┌───────────────┐
                            │  Controller   │
                            └───────┬───────┘
                                    ▼
                          shouldHideMenuBar — all of:
                          (1) active Space is FS
                          (2) media is playing
                          (3) frontmost owns FS Space (multi-display gate)
                          (4) frontmost is the Now Playing source
                                    │
                                    ▼
                               HIDE or SHOW
                                    │
                                    ▼
                       AppleMenuBarVisibleInFullscreen
                       + DistributedNotification (WindowServer reads the pref)
```

Internally:

- **(1) and (2)** come from Dock's `dock-visibility` log channel, tapped by spawning `/usr/bin/log stream`. The predicate filters to two message shapes:
  - `Space Forces Hidden:` — emitted on FS entry/exit, carries the active Space's fullscreen flag and the FS app's PID.
  - `Skipping no-op state update` — emitted on FS↔FS Space switches where Dock's own visibility doesn't need to flip; a payload-less wake-up pulse that lets us refresh the cached FS owner from `NSWorkspace.frontmostApplication`. Without this, switching directly between two fullscreen apps would keep the menu bar in the wrong state.
- **(3)** comes from the system MediaRemote framework via the vendored `mediaremote-adapter` subprocess (perl is on Apple's MediaRemote allowlist; an unentitled Swift binary isn't).

All signals are public, unentitled APIs.

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

## Usage

```bash
brew services start   houdini     # start and enable at login
brew services stop    houdini     # stop and disable
brew services restart houdini     # stop + start
brew services info    houdini     # state, PID, plist path
```

Running the binary directly (`./houdini`) is useful for debugging; `brew services` is the normal path.

## Diagnostics

```bash
houdini status                    # print version and whether a daemon
                                  # is running
houdini logs                      # stream every houdini unified-log entry
                                  # across all categories at debug level
                                  # (controller decisions, dock-visibility
                                  # events, mediaremote-adapter output,
                                  # startup notices); wraps
                                  # `log stream --predicate …`
houdini version                   # print version
houdini help                      # full usage
```

`houdini status` is the fastest way to confirm the install: which version is in your `$PATH` and whether a daemon currently holds the instance lock. Exits non-zero if the daemon isn't running, so it composes in scripts. For the live decision (frontmost app, Now Playing, HIDE/SHOW), watch `houdini logs`.

Everything goes to the macOS unified log under subsystem `com.github.mgxv.houdini`, organized into three categories:

- `controller` — HIDE/SHOW snapshots (info) plus parsed `dock_visibility` events from the Dock log channel (debug)
- `adapter` — output from the mediaremote-adapter subprocess (debug)
- `general` — startup/shutdown notices, warnings, errors (info)

`houdini logs` streams everything across all three categories at debug level — no flags, one stream, ready to copy-paste into a bug report. The system handles retention and rotation; nothing on disk to manage.

```bash
houdini logs                                              # live stream — everything, debug level
log show --predicate 'subsystem == "com.github.mgxv.houdini"' --last 1h   # history
```

Or open Console.app, filter on subsystem `com.github.mgxv.houdini`, and toggle **Action → Include Debug Messages** / **Include Info Messages**.

## Troubleshooting

### The menu bar isn't hiding

Run `houdini logs` and exercise the trigger you expect to hide the bar (fullscreen the app, start playback). Each evaluation prints a HIDE/SHOW snapshot with the inputs that drove it:

```
HIDE  front=Safari[pid=501,name="Safari",bundle=com.apple.Safari,fs=yes,fsPid=501]
np=WebKit.GPU[pid=506,bundle=com.apple.WebKit.GPU,parent=com.apple.Safari,resp=501,play=yes]
```

Hide requires all of: `fs=yes` (Dock has reported a fullscreen Space), the frontmost `pid` matching `fsPid` (the FS-Space owner), `play=yes`, and frontmost/Now-Playing resolving to the same app. Common reasons a SHOW is logged when you expected HIDE:

- **`fs=no`** — Dock has not reported a fullscreen Space transition. Native fullscreen (⌃⌘F, the green-stoplight button, or in-page fullscreen buttons in YouTube, Netflix, QuickTime) creates a dedicated Space; merely-maximized windows that just fill the screen don't qualify.
- **`fs=yes` but `pid ≠ fsPid`** — a fullscreen Space exists, but the frontmost app isn't its owner. Typically you've Cmd-Tab'd to a different app whose window is now in front; the menu bar belongs to the frontmost app, not to the (still-fullscreen) Space underneath.
- **`np=[pid=null,...]`** — nothing is using Now Playing. Some players (e.g. a browser tab playing inline video with no media session metadata) never register with the system Now Playing widget.
- **`play=no`** — the Now Playing source is paused; play/pause state comes directly from the media app.
- **front bundle ≠ np parent and `resp` doesn't match the frontmost pid** — e.g. Spotify is playing in the background while Safari is the focused fullscreen app.

### Is it actually running?

```bash
houdini status                     # prints `daemon: running` / `not running`;
                                   # exits non-zero if not running
brew services info houdini         # launchd view: Running / Loaded / PID
pgrep -afl houdini                 # confirms the Swift daemon is alive
pgrep -afl mediaremote-adapter     # confirms the Perl Now-Playing subprocess
pgrep -afl 'log stream.*dock'      # confirms the dock-visibility subscription
```

A healthy install shows **three** processes — the `houdini` binary plus two subprocesses it spawns:

- `/usr/bin/perl … mediaremote-adapter.pl stream …` — Now-Playing event source
- `/usr/bin/log stream --predicate …com.apple.dock…` — Dock fullscreen-state event source

If either subprocess dies unexpectedly, the daemon emits an error to the unified log (see `houdini logs`) and exits; launchd then relaunches it via `brew services`.

### Starting clean

If state feels stuck (menu bar hidden when it shouldn't be, orphan subprocesses, a foreground `./houdini` you forgot about):

```bash
brew services stop houdini
pkill -x houdini                   # kill any foreground or orphan houdini
pkill -f mediaremote-adapter       # kill any orphan Perl subprocesses
brew services start houdini
```

houdini terminates its child `log stream` subprocess on shutdown, so a separate `pkill` for it isn't needed.

## Project layout

```
scripts/              # Build and release scripts
  build.sh            # Builds the framework + Swift binary (canonical path)
  release.sh          # Version bump → tag → formula update → tap mirror
Formula/houdini.rb    # Homebrew formula
Package.swift         # Optional SwiftPM manifest (for IDE indexing)
Sources/              # Swift daemon + CLI (Swift 6, strict concurrency)
Sources/Version.swift # Single source of truth for the version string
vendor/               # mediaremote-adapter (Obj-C + Perl shim)
```

## Acknowledgements

houdini is built on top of [**mediaremote-adapter**](https://github.com/ungive/mediaremote-adapter) by [Jonas van den Berg (@ungive)](https://github.com/ungive). Without it, there would be no practical way for an unentitled binary to observe Now Playing state on modern macOS. Huge thanks to Jonas and the project's contributors.

The vendored sources under `vendor/mediaremote-adapter/` are distributed under the BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).

## License

houdini is released under the MIT License. See [`LICENSE`](./LICENSE) for the full text.

The vendored `mediaremote-adapter` retains its own BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).
