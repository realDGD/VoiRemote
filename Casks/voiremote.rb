cask "voiremote" do
  version "0.3.5"
  sha256 "7033896c35d546dc96315b3dfc06344bb9b8ac058b922ee6c0b28c2c5f4cdad0"

  url "https://github.com/realDGD/VoiRemote/archive/f882b4e4a1eca10a4a5924cfa22ffb1ba275ab17.tar.gz"
  name "VoiRemote"
  desc "Native macOS remote key mapping and voice app compiled with CLT"
  homepage "https://github.com/realDGD/VoiRemote"

  depends_on macos: :sonoma

  preflight_steps do
    run "/bin/bash", args: ["scripts/build-cask.sh", "0.3.5", "f882b4e4a1eca10a4a5924cfa22ffb1ba275ab17", "7033896c35d546dc96315b3dfc06344bb9b8ac058b922ee6c0b28c2c5f4cdad0"],
                      chdir: "VoiRemote-f882b4e4a1eca10a4a5924cfa22ffb1ba275ab17", print_stdout: true,
                      env: { "DEVELOPER_DIR" => "/Library/Developer/CommandLineTools" }
  end

  installer script: {
    executable: "VoiRemote-f882b4e4a1eca10a4a5924cfa22ffb1ba275ab17/scripts/install-cask-app.sh",
    args: ["#{appdir}/VoiRemote.app", "f882b4e4a1eca10a4a5924cfa22ffb1ba275ab17"],
  }
  binary "VoiRemote-f882b4e4a1eca10a4a5924cfa22ffb1ba275ab17/packaging/homebrew/voiremote"

  postflight_steps do
    remove ["VoiRemote-f882b4e4a1eca10a4a5924cfa22ffb1ba275ab17/.build", "VoiRemote-f882b4e4a1eca10a4a5924cfa22ffb1ba275ab17/.swiftpm"], recursive: true
  end

  uninstall quit: "dev.voiremote.app",
            script: {
              executable: "VoiRemote-f882b4e4a1eca10a4a5924cfa22ffb1ba275ab17/scripts/uninstall-cask-app.sh",
              args: ["#{appdir}/VoiRemote.app", "f882b4e4a1eca10a4a5924cfa22ffb1ba275ab17"],
            }

  zap trash: [
    "~/Library/Application Support/VoiRemote",
    "~/Library/Caches/dev.voiremote.app",
    "~/Library/Preferences/ByHost/dev.voiremote.app.*.plist",
    "~/Library/Preferences/dev.voiremote.app.plist",
    "~/Library/Saved Application State/dev.voiremote.app.savedState",
  ]

  caveats <<~EOS
    This single cask compiles the fixed source archive using Swift 6 Command Line Tools.
    It installs one app in Applications; no companion formula or audio driver is installed.
    Source builds use identifier-only ad-hoc signing, which does not authenticate the signer.
    Changing from older hash-bound builds may require re-authorizing this app once.
    Gatekeeper approval is separate; this app is not Developer ID signed or notarized.
    Run voiremote --self-check to check the installed configuration code without devices.
    Uninstall with brew uninstall --cask realdgd/voiremote/voiremote; add --zap to clear this app's settings.
    brew test supports formulae only; source checks run during installation.
  EOS
end
