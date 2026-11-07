cask "voiremote" do
  version "0.3.6"
  sha256 "7374768b73a9b26edce1b7a5131913e3a2eb6db1f891d95cace10449416b4d6e"

  url "https://github.com/realDGD/VoiRemote/archive/bc0e4857f9c4f723841d34782199b706ee54f600.tar.gz"
  name "VoiRemote"
  desc "Native macOS remote key mapping and voice app compiled with CLT"
  homepage "https://github.com/realDGD/VoiRemote"

  depends_on macos: :sonoma

  preflight_steps do
    run "/bin/bash", args: ["scripts/build-cask.sh", "0.3.6", "bc0e4857f9c4f723841d34782199b706ee54f600", "7374768b73a9b26edce1b7a5131913e3a2eb6db1f891d95cace10449416b4d6e"],
                      chdir: "VoiRemote-bc0e4857f9c4f723841d34782199b706ee54f600", print_stdout: true,
                      env: { "DEVELOPER_DIR" => "/Library/Developer/CommandLineTools" }
  end

  installer script: {
    executable: "VoiRemote-bc0e4857f9c4f723841d34782199b706ee54f600/scripts/install-cask-app.sh",
    args: ["#{appdir}/VoiRemote.app", "bc0e4857f9c4f723841d34782199b706ee54f600"],
  }
  binary "VoiRemote-bc0e4857f9c4f723841d34782199b706ee54f600/packaging/homebrew/voiremote"

  postflight_steps do
    remove ["VoiRemote-bc0e4857f9c4f723841d34782199b706ee54f600/.build", "VoiRemote-bc0e4857f9c4f723841d34782199b706ee54f600/.swiftpm"], recursive: true
  end

  uninstall quit: "dev.voiremote.app",
            script: {
              executable: "VoiRemote-bc0e4857f9c4f723841d34782199b706ee54f600/scripts/uninstall-cask-app.sh",
              args: ["#{appdir}/VoiRemote.app", "bc0e4857f9c4f723841d34782199b706ee54f600"],
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
