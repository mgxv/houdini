class Houdini < Formula
  desc "Hides the menu bar when the frontmost fullscreen app is playing in Now Playing"
  homepage "https://github.com/mgxv/houdini"
  url "https://github.com/mgxv/houdini/archive/refs/tags/v0.18.2.tar.gz"
  sha256 "3153f4448f7e140be1dac0bf00e951128a1ab08d6ba03018191f0c0659494ae4"
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
      Manual override
      ---------------------------------------------------------------
      ⌃⌥⌘M flips the menu bar against the daemon's decision until
      the next signal change. See the README for behavior and mode
      differences:

          https://github.com/mgxv/houdini#modes

      After each upgrade, restart the daemon — macOS treats the
      freshly-signed binary as a new identity:

          brew services restart houdini

    EOS
  end

  test do
    assert_match "houdini —", shell_output("#{bin}/houdini help")
  end
end
