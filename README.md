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

## How it works

houdini hides the menu bar only when **all three** are true:

1. An app is in native fullscreen
2. That app is the frontmost (focused) app
3. That same app is actively playing media via Now Playing

When any one becomes false, the menu bar comes back.

**Hardware note.** Houdini is best on notched MacBooks (14"/16" MacBook Pro 2021+, 13"/15" MacBook Air 2024+).

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

houdini needs Accessibility to detect whether the frontmost app is in fullscreen.

- `brew services start houdini` — triggers the prompt on a fresh install
- `brew services restart houdini` — re-triggers it when permission is missing (after an upgrade, after revocation, or if the original prompt was dismissed)

The restart form works in both cases, so when in doubt, use it.

## Usage

```bash
brew services start   houdini     # start and enable at login
brew services stop    houdini     # stop and disable
brew services restart houdini     # stop + start
brew services info    houdini     # state, PID, plist path
```

Running the binary directly `houdini` is useful for debugging; `brew services` is the normal path.

## Diagnostics

```bash
houdini status                    # print version, whether a daemon is
                                  # running, and whether Accessibility
                                  # is granted
houdini logs                      # stream every houdini unified-log entry
                                  # across all categories at debug level
                                  # (controller decisions, fullscreen
                                  # diagnostics, mediaremote-adapter
                                  # output, startup notices); wraps
                                  # `log stream --predicate …`
houdini version                   # print version
houdini help                      # full usage
```

`houdini status` is the fastest way to confirm the install: which version is in your `$PATH`, whether a daemon currently holds the instance lock, and whether Accessibility has been granted. Exits non-zero if the daemon isn't running or Accessibility is missing, so it composes in scripts. For the live decision (frontmost app, Now Playing, HIDE/SHOW), watch `houdini logs`.

Everything goes to the macOS unified log under subsystem `com.github.mgxv.houdini`, organized into three categories:

- `controller` — HIDE/SHOW snapshots (info) plus the per-window `isAppFullScreen` diagnostic (debug)
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
HIDE  front=Safari[pid=501,name="Safari",bundle=com.apple.Safari,fs=yes]
np=WebKit.GPU[pid=506,bundle=com.apple.WebKit.GPU,parent=com.apple.Safari,resp=501,play=yes]
```

Hide requires all of: `fs=yes`, `play=yes`, and frontmost/Now-Playing resolving to the same app. Common reasons a SHOW is logged when you expected HIDE:

- **`fs=no`** — requires native fullscreen: ⌃⌘F, the green-stoplight button, or in-page fullscreen buttons (YouTube, Netflix, QuickTime). Merely-maximized windows that just fill the screen don't qualify.
- **`np=...[pid=null,...]`** — nothing is using Now Playing. Some players (e.g. a browser tab playing inline video with no media session metadata) never register with the system Now Playing widget.
- **`play=no`** — the Now Playing source is paused; play/pause state comes directly from the media app.
- **front bundle ≠ np parent and `resp` doesn't match the frontmost pid** — e.g. Spotify is playing in the background while Safari is the focused fullscreen app.

### Is it actually running?

```bash
houdini status                     # prints `daemon: running` / `not running`;
                                   # exits non-zero if not running or AX missing
brew services info houdini         # launchd view: Running / Loaded / PID
pgrep -afl houdini                 # confirms the Swift daemon is alive
pgrep -afl mediaremote-adapter     # confirms the Perl subprocess it spawns
```

A healthy install shows **two** processes — the `houdini` binary and the `/usr/bin/perl … mediaremote-adapter.pl stream …` child it spawns for Now-Playing events. If the Perl child dies, the daemon emits an error to the unified log (see `houdini logs`) and exits; launchd then relaunches it via `brew services`.

### Safari fullscreen on the first video

Safari sometimes won't honor an in-page fullscreen click — YouTube, Netflix, Vimeo, Twitch, Apple TV+, any site using the HTML5 `requestFullscreen()` API — as native macOS fullscreen on the first request after a fresh Safari launch with autoplaying media. ⌃⌘F can also fail in this state. **Workaround:** pause the video and resume it once, then trigger fullscreen again — every cycle for the rest of the session works normally.

This is an upstream WebKit quirk, not a houdini bug. In the broken state AX never reports a fullscreen window — `houdini logs` shows `ax_windows=1 … result=false` with the same single window throughout, no new window appearing, no `fs=true` — so the daemon has nothing to react to. Pause+resume nudges WebKit's media-session state and the next fullscreen request goes through as native fullscreen.

### Accessibility permission

If you revoke Accessibility while the daemon is running, `houdini logs` will show:

```
Accessibility permission appears to have been revoked; fullscreen detection is disabled.
```

(The same message is echoed to stderr with a `houdini:` prefix when the binary runs in a foreground terminal.) To recover, run:

```bash
brew services restart houdini
```

That re-triggers the Accessibility prompt; toggle houdini back on.

### Starting clean

If state feels stuck (menu bar hidden when it shouldn't be, orphan subprocesses, a foreground `./houdini` you forgot about):

```bash
brew services stop houdini
pkill -x houdini                   # kill any foreground or orphan houdini
pkill -f mediaremote-adapter       # kill any orphan Perl subprocesses
brew services start houdini
```

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
