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

Logs stream to `/opt/homebrew/var/log/houdini.log` (and `.err` for errors).

Running the binary directly `houdini` is useful for debugging; `brew services` is the normal path.

### Diagnostic subcommands

```bash
houdini status                    # print frontmost / Now-Playing state and the
                                  # hide/show decision the daemon would make
houdini logs <out|err>            # stream new lines from houdini.log (out)
                                  # or houdini.err (err)
houdini version                   # print version
houdini help                      # full usage
```

`houdini status` is the fastest way to verify what the daemon is seeing — it samples the same inputs (frontmost app, Accessibility fullscreen state, Now Playing) independently of the running daemon, so it's safe to run at any time.


## Troubleshooting

### Is it actually running?

```bash
brew services info houdini         # launchd view: Running / Loaded / PID
pgrep -afl houdini                 # confirms the Swift daemon is alive
pgrep -afl mediaremote-adapter     # confirms the Perl subprocess it spawns
```

A healthy install shows **two** processes — the `houdini` binary and the `/usr/bin/perl … mediaremote-adapter.pl stream …` child it spawns for Now-Playing events. If houdini is alive but the Perl child is missing, the daemon will log an error to `houdini.err` and exit.

### The menu bar isn't hiding

Run `houdini status` — it re-samples the same three inputs the daemon uses and names the first unmet precondition:

```
front:    Safari (pid=501, fullscreen=yes)
playing:  com.spotify.client (pid=1337, playing=yes)
decision: SHOW  (frontmost and Now Playing are different processes)
```

Common reasons:

- **`frontmost is not fullscreen`** — only native fullscreen (⌃⌘F) counts, not maximized windows
- **`nothing is using Now Playing`** — some players (e.g. a browser tab playing inline video with no media session metadata) never register with the system Now Playing widget
- **`the Now Playing source is paused`** — play/pause state comes directly from the media app
- **`frontmost and Now Playing are different processes`** — e.g. Spotify is playing in the background while Safari is the focused fullscreen app

### Accessibility permission

If you revoke Accessibility while the daemon is running, `houdini.err` will contain:

```
houdini: Accessibility permission appears to have been revoked; fullscreen detection is disabled.
```

Re-grant in *System Settings → Privacy & Security → Accessibility*, then:

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

### Log files

- `/opt/homebrew/var/log/houdini.log` — HIDE/SHOW decisions with timestamps
- `/opt/homebrew/var/log/houdini.err` — errors; output from the subprocess is prefixed `[adapter]` so it's distinguishable from houdini's own warnings

Each file is capped at 500 KB: on daemon startup, if either is larger, it's truncated in place (no rotated archive). This keeps disk usage bounded without external tooling like `newsyslog`.

Stream either via `houdini logs out` or `houdini logs err` — that command handles the Apple Silicon vs Intel Homebrew path automatically and prints new lines as they're written.


## Project layout

```
build.sh            # Builds the framework + Swift binary
Formula/houdini.rb  # Homebrew formula
Sources/            # Swift daemon + CLI
vendor/             # mediaremote-adapter (Obj-C + Perl shim)
```

## Acknowledgements

houdini is built on top of [**mediaremote-adapter**](https://github.com/ungive/mediaremote-adapter) by [Jonas van den Berg (@ungive)](https://github.com/ungive). Without it, there would be no practical way for an unentitled binary to observe Now Playing state on modern macOS. Huge thanks to Jonas and the project's contributors.

The vendored sources under `vendor/mediaremote-adapter/` are distributed under the BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).

## License

houdini is released under the MIT License. See [`LICENSE`](./LICENSE) for the full text.

The vendored `mediaremote-adapter` retains its own BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).
