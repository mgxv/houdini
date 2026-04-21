class Houdini < Formula
  desc "Hides the menu bar when the frontmost fullscreen app is playing in Now Playing"
  homepage "https://github.com/mgxv/houdini"
  url "https://github.com/mgxv/houdini/archive/refs/tags/v0.7.2.tar.gz"
  sha256 "71e3bcaa744858ae605811a292b6b727334d0fcbed8497c22c83aedd7b9639ba"
  license "MIT"

  depends_on macos: :sequoia

  def install
    # build.sh handles everything: compiles the Obj-C framework universally,
    # compiles the Swift binary, and (when PREFIX is set) stages them as:
    #   #{prefix}/bin/houdini
    #   #{prefix}/libexec/houdini/MediaRemoteAdapter.framework
    #   #{prefix}/libexec/houdini/vendor/
    ENV["PREFIX"] = prefix
    system "./build.sh"
  end

  service do
    run opt_bin/"houdini"
    keep_alive true
  end

  def caveats
    <<~EOS
      houdini needs Accessibility permission to detect the frontmost
      fullscreen app. On first start it will prompt; if you miss the
      prompt, open:

        System Settings → Privacy & Security → Accessibility

      and grant access to:

        #{opt_bin}/houdini

      Then restart the service:

        brew services restart houdini

      NOTE: every `brew upgrade houdini` produces a freshly-signed binary,
      which macOS treats as a distinct identity for Accessibility
      purposes. You will need to re-grant permission after each upgrade.
    EOS
  end

  test do
    assert_match "houdini —", shell_output("#{bin}/houdini help")
  end
end
