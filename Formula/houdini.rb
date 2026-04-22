class Houdini < Formula
  desc "Hides the menu bar when the frontmost fullscreen app is playing in Now Playing"
  homepage "https://github.com/mgxv/houdini"
  url "https://github.com/mgxv/houdini/archive/refs/tags/v0.8.0.tar.gz"
  sha256 "4749600c721c17a2713d1b5a0c7244209f35fc4b790c942e3752b8813f42b0fb"
  license "MIT"

  depends_on macos: :sequoia

  def install
    # build.sh compiles the framework + binary and (via $PREFIX) stages:
    #   #{prefix}/bin/houdini
    #   #{prefix}/libexec/houdini/MediaRemoteAdapter.framework
    #   #{prefix}/libexec/houdini/vendor/
    ENV["PREFIX"] = prefix
    system "./build.sh"
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
      houdini needs Accessibility to detect whether the frontmost app
      is in fullscreen. On first start the daemon will prompt; if you
      miss the prompt, grant access manually:

        1. Open System Settings → Privacy & Security → Accessibility
        2. Grant access to:
             #{opt_bin}/houdini
        3. Restart the service:
             brew services restart houdini

      After upgrading
      ---------------------------------------------------------------
      `brew upgrade houdini` installs a freshly-signed binary, which
      macOS treats as a new identity for Accessibility — the existing
      grant no longer applies. Repeat the steps above after every
      upgrade.

      How it works
      ---------------------------------------------------------------
      macOS doesn't expose "is media playing inside this window," so
      houdini watches two signals independently:

        - which app is frontmost and in fullscreen, and
        - which app owns the system Now Playing widget.

      When those match and the app is actively playing, the menu bar
      hides. Switching apps, exiting fullscreen, or pausing brings it
      back. In practice: fullscreen YouTube, Netflix, QuickTime, and
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
