# houdini

A macOS background daemon that auto-hides the menu bar when the frontmost fullscreen app is the one currently playing in the system **Now Playing** widget.

Watching a video in fullscreen? The menu bar disappears. Switch to another window, pause, or focus a non-media app? It comes back. No UI, no hotkeys.

## How it works

houdini fuses two signals:

- **Now Playing state** (play/pause + originating app) via the vendored [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter).
- **Frontmost fullscreen state** via the macOS Accessibility API.

When both point to the same app, it flips the `AppleMenuBarVisibleInFullscreen` system preference and nudges WindowServer to re-apply the policy. When either stops being true, it flips back.

## Getting started

### Prerequisites

- macOS with Xcode command-line tools (`swiftc`, `clang`, `codesign`)
- Swift **6.2.3** (pinned in `.swift-version`)
- Accessibility permission (you'll be prompted on first run)

> **Note:** a minimum supported macOS version isn't declared yet — please flag if you hit a version mismatch.

### Build & install

```bash
./build.sh             # Builds MediaRemoteAdapter.framework + the houdini binary
./houdini install      # Registers a LaunchAgent + symlinks into ~/.local/bin
```

After install, houdini runs on login and keeps itself alive via `launchd`.

### Usage

```
houdini [--dry-run]     Run in foreground (dry-run = observe, don't toggle)
houdini install         Install LaunchAgent + autostart
houdini uninstall       Stop, clean up, and restore the menu bar
houdini status          Show install state, paths, and current pref
houdini help            Print help
```

Logs live at `~/Library/Logs/houdini.log` when installed.

## Project layout

```
build.sh          # Builds the framework + Swift binary
Sources/          # Swift source (daemon, CLI, LaunchAgent management)
vendor/           # mediaremote-adapter (Obj-C + Perl shim)
```

Build outputs (`MediaRemoteAdapter.framework/` and `houdini`) land at the project root and must stay side by side — the binary resolves the framework by path at runtime.

## Acknowledgements

houdini is built on top of [**mediaremote-adapter**](https://github.com/ungive/mediaremote-adapter) by [Jonas van den Berg (@ungive)](https://github.com/ungive). Without it, there would be no practical way for an unentitled binary to observe Now Playing state on modern macOS. Huge thanks to Jonas and the project's contributors.

The vendored sources under `vendor/mediaremote-adapter/` are distributed under the BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).

## License

houdini is released under the MIT License. See [`LICENSE`](./LICENSE) for the full text.

The vendored `mediaremote-adapter` retains its own BSD 3-Clause License — see [`vendor/mediaremote-adapter/LICENSE`](./vendor/mediaremote-adapter/LICENSE) (upstream: <https://github.com/ungive/mediaremote-adapter/blob/master/LICENSE>).
