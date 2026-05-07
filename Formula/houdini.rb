class Houdini < Formula
  desc "Hides the menu bar when the frontmost fullscreen app is playing in Now Playing"
  homepage "https://github.com/mgxv/houdini"
  url "https://github.com/mgxv/houdini/archive/refs/tags/v0.18.0.tar.gz"
  sha256 "f62ec9a48ddb1e279279bed96f9af6308a0275e108afd8055d6d40e35ae088d6"
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
      the next signal change. See the README for behavior and
      mode differences:

          https://github.com/mgxv/houdini#hotkey
    EOS
  end

  test do
    assert_match "houdini —", shell_output("#{bin}/houdini help")
  end
end
