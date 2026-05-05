class Houdini < Formula
  desc "Hides the menu bar when the frontmost fullscreen app is playing in Now Playing"
  homepage "https://github.com/mgxv/houdini"
  url "https://github.com/mgxv/houdini/archive/refs/tags/v0.17.0.tar.gz"
  sha256 "9c36079cab81b0eae7b11f094b7a2674abd6b9ee2fdd8d7ab08006f2f859bdb1"
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
      First start prompts for Accessibility — distinguishes two
      windows of the same app (e.g. the playing Chrome tab vs. a
      different fullscreen Chrome window). Without it, the daemon
      falls back to process-level matching only.

      If you dismiss the prompt, revoke it, or run `brew upgrade`
      (macOS treats the freshly-signed binary as a new identity),
      restart to re-prompt:

          brew services restart houdini

      Manual override
      ---------------------------------------------------------------
      ⌃⌥⌘M flips the menu bar against the daemon's decision —
      sticky to the tab/window where you set it. See the README
      for matching rules and edge cases:

          https://github.com/mgxv/houdini#manual-override
    EOS
  end

  test do
    assert_match "houdini —", shell_output("#{bin}/houdini help")
  end
end
