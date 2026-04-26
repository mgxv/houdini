# houdini

A macOS background daemon that hides the menu bar when the frontmost fullscreen app is the one currently playing in the system **Now Playing** widget.

Watching a video in fullscreen? The menu bar disappears. Switch windows, pause, or focus a non-media app? It comes back. No UI, no hotkeys.

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

On first start you'll be prompted to grant Accessibility permission. After granting, run `brew services restart houdini` once to pick it up.

## How it works

houdini hides the menu bar only when **all three** are true:

1. An app is in native fullscreen
2. That app is the frontmost (focused) app
3. That same app is actively playing media via Now Playing

When any one becomes false, the menu bar comes back.

## Usage

```bash
brew services start   houdini     # start and enable at login
brew services stop    houdini     # stop and disable
brew services restart houdini     # stop + start
brew services info    houdini     # state, PID, plist path
```

Logs go to the macOS unified log under subsystem `com.github.mgxv.houdini`. Stream them with `houdini logs` or view in Console.app.

Running the binary directly `houdini` is useful for debugging; `brew services` is the normal path.

### Diagnostic subcommands

```bash
houdini status                    # print frontmost / Now-Playing state and the
                                  # hide/show decision the daemon would make
houdini logs                      # stream every houdini unified-log entry
                                  # across all categories at debug level
                                  # (controller decisions, fullscreen
                                  # diagnostics, mediaremote-adapter
                                  # output, startup notices); wraps
                                  # `log stream --predicate …`
houdini version                   # print version
houdini help                      # full usage
```

`houdini status` is the fastest way to verify what the daemon is seeing — it reports whether a daemon is running and samples the same inputs (frontmost app, Accessibility fullscreen state, Now Playing) independently of it, so it's safe to run at any time.


## Troubleshooting

### Is it actually running?

```bash
houdini status                     # prints `daemon: running` or `not running`
brew services info houdini         # launchd view: Running / Loaded / PID
pgrep -afl houdini                 # confirms the Swift daemon is alive
pgrep -afl mediaremote-adapter     # confirms the Perl subprocess it spawns
```

A healthy install shows **two** processes — the `houdini` binary and the `/usr/bin/perl … mediaremote-adapter.pl stream …` child it spawns for Now-Playing events. If the Perl child dies, the daemon emits an error to the unified log (see `houdini logs`) and exits; launchd then relaunches it via `brew services`.

### The menu bar isn't hiding

Run `houdini status` — it re-samples the same three inputs the daemon uses and names the first unmet precondition:

```
daemon:   running
front:    Safari (pid=501, fullscreen=yes)
playing:  com.spotify.client (pid=1337, playing=yes)
decision: SHOW  (frontmost and Now Playing are different processes)
```

Common reasons:

- **`frontmost is not fullscreen`** — requires native fullscreen: ⌃⌘F, the green-stoplight button, or in-page fullscreen buttons (YouTube, Netflix, QuickTime). Merely-maximized windows that just fill the screen don't qualify.
- **`nothing is using Now Playing`** — some players (e.g. a browser tab playing inline video with no media session metadata) never register with the system Now Playing widget
- **`the Now Playing source is paused`** — play/pause state comes directly from the media app
- **`frontmost and Now Playing are different processes`** — e.g. Spotify is playing in the background while Safari is the focused fullscreen app

### Safari fullscreen on the first video

Safari sometimes won't honor an in-page fullscreen click — YouTube, Netflix, Vimeo, Twitch, Apple TV+, any site using the HTML5 `requestFullscreen()` API — as native macOS fullscreen on the first request after a fresh Safari launch with autoplaying media. ⌃⌘F can also fail in this state. **Workaround:** pause the video and resume it once, then trigger fullscreen again — every cycle for the rest of the session works normally.

This is an upstream WebKit quirk, not a houdini bug. In the broken state AX never reports a fullscreen window — `houdini logs` shows `ax_windows=1 … result=false` with the same single window throughout, no new window appearing, no `fs=true` — so the daemon has nothing to react to. Pause+resume nudges WebKit's media-session state and the next fullscreen request goes through as native fullscreen.

### Accessibility permission

If you revoke Accessibility while the daemon is running, `houdini logs` will show:

```
Accessibility permission appears to have been revoked; fullscreen detection is disabled.
```

(The same message is echoed to stderr with a `houdini:` prefix when the binary runs in a foreground terminal.) Re-grant in *System Settings → Privacy & Security → Accessibility*, then:

```bash
brew services restart houdini
```

### Starting clean

If state feels stuck (menu bar hidden when it shouldn't be, orphan subprocesses, a foreground `./houdini` you forgot about):

```bash
brew services stop houdini
pkill -x houdini                   # kill any foreground or orphan houdini
pkill -f mediaremote-adapter       # kill any orphan Perl subprocesses
brew services start houdini
```

### Logs

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


## Project layout

```
scripts/              # Build, release, and vendor-sync scripts
  build.sh            # Builds the framework + Swift binary (canonical path)
  release.sh          # Version bump → tag → formula update → tap mirror
  sync.sh             # Refreshes vendor/ from the latest mediaremote-adapter release
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
