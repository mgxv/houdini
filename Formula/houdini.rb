class Houdini < Formula
  desc "Hides the menu bar when the frontmost fullscreen app is playing in Now Playing"
  homepage "https://github.com/mgxv/houdini"
  url "https://github.com/mgxv/houdini/archive/refs/tags/v0.15.1.tar.gz"
  sha256 "3e3f018afe393d9644edb2a8da0f320fd5240e15a4510b8dfb235a4a163c4a68"
  license "MIT"

  depends_on macos: :sequoia

  def install
    # scripts/build.sh compiles the framework + binary and (via $PREFIX) stages:
    #   #{prefix}/bin/houdini
    #   #{prefix}/libexec/houdini/MediaRemoteAdapter.framework
    #   #{prefix}/libexec/houdini/vendor/
    ENV["PREFIX"] = prefix
    system "./scripts/build.sh"
  end

  # Keep-alive LaunchAgent. Logs go to the macOS unified log under
  # subsystem com.github.mgxv.houdini — stream with `houdini logs`.
  service do
    run opt_bin/"houdini"
    keep_alive true
  end

  def caveats
    <<~EOS
      Accessibility permission
      ---------------------------------------------------------------
      houdini uses Accessibility to read the focused window's title
      — distinguishes two windows of the same app (e.g. the playing
      Chrome tab vs. a different fullscreen Chrome window). Without
      it, the daemon falls back to process-level matching only.

      Triggers (or re-triggers) the prompt — fresh install, after
      revocation, or if the original was dismissed:

          brew services restart houdini

      After upgrading
      ---------------------------------------------------------------
      `brew upgrade` installs a freshly-signed binary that macOS
      treats as a new Accessibility identity, and doesn't cycle the
      running daemon. Restart to pick up both:

          brew services restart houdini

      How it works
      ---------------------------------------------------------------
      macOS doesn't expose "is media playing inside this window," so
      houdini fuses four signals:

        - Dock log       — fullscreen state + FS owner's pid
        - AppKit         — frontmost app
        - MediaRemote    — Now Playing (playing flag, pid, parent
                           bundle, track title)
        - Accessibility  — focused window's title (window-level
                           refinement)

      The menu bar hides when a fullscreen Space is active, the
      frontmost app owns it, that app is the Now Playing source,
      and the focused window's title contains the playing track.
      Switching apps, switching to a non-playing tab/window of the
      same app, exiting fullscreen, or pausing brings it back. In
      practice: fullscreen YouTube, Netflix, Apple TV+, and Spotify
      hide the bar; fullscreen Terminal doesn't.

      Manual override
      ---------------------------------------------------------------
      ⌃⌥⌘M (Ctrl+Option+Cmd+M) flips the menu bar regardless of
      what the daemon decided — force-hide if showing, force-show
      if hidden. One-shot: the next real event (frontmost change,
      fullscreen toggle, AX focus, Now Playing update) yields
      control back to the daemon.

      Useful when AX title-changed events are delayed or missed
      and the window-title gate gets stuck on stale state.

      Limitations
      ---------------------------------------------------------------
      Window-level matching relies on the playing app putting the
      track title in its window title — most browsers and the
      system Music / Apple TV apps do. Without Accessibility
      permission, the window-title check is skipped and the bar
      hides as soon as any window of the playing app is fullscreen
      and frontmost.
    EOS
  end

  test do
    assert_match "houdini —", shell_output("#{bin}/houdini help")
  end
end
