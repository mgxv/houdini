class Houdini < Formula
  desc "Hides the menu bar when the frontmost fullscreen app is playing in Now Playing"
  homepage "https://github.com/mgxv/houdini"
  url "https://github.com/mgxv/houdini/archive/refs/tags/v0.11.2.tar.gz"
  sha256 "b638e735a4679241423a640f52e11f31e59d6e121bcb0a59030d3f16b40f0c1c"
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
      After upgrading
      ---------------------------------------------------------------
      `brew upgrade houdini` installs the new binary on disk but
      doesn't cycle the running daemon, so the old version stays
      resident until you restart:

          brew services restart houdini

      How it works
      ---------------------------------------------------------------
      macOS doesn't expose "is media playing inside this window," so
      houdini watches two signals independently:

        - which app is frontmost and in fullscreen, and
        - which app owns the system Now Playing widget.

      When those match and the app is actively playing, the menu bar
      hides. Switching apps, exiting fullscreen, or pausing brings it
      back. In practice: fullscreen YouTube, Netflix, Apple TV+, and
      Spotify will hide the bar. Fullscreen Terminal won't.

      Limitations
      ---------------------------------------------------------------
      No tab-level granularity inside a single process. Fullscreen
      Chrome with audio playing in one tab keeps the bar hidden even
      when you switch to another tab within Chrome — houdini can't
      see into the process to tell which tab is actually visible.
      Rare in practice.
    EOS
  end

  test do
    assert_match "houdini —", shell_output("#{bin}/houdini help")
  end
end
