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
