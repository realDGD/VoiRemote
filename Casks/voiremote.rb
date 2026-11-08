cask "voiremote" do
  version "0.3.7"
  sha256 "fefd7f588b146aa16b90b47c549b9fe4d91bcaa5ddcb1157e90cfbb8a3be8ade"

  url "https://github.com/realDGD/VoiRemote/archive/edc142e008401777935788977d5196dc10d982ba.tar.gz"
  name "VoiRemote"
  desc "Native macOS remote key mapping and voice app compiled with CLT"
  homepage "https://github.com/realDGD/VoiRemote"

  depends_on macos: :sonoma

  preflight_steps do
    run "/bin/bash", args: ["scripts/build-cask.sh", "0.3.7", "edc142e008401777935788977d5196dc10d982ba", "fefd7f588b146aa16b90b47c549b9fe4d91bcaa5ddcb1157e90cfbb8a3be8ade"],
                      chdir: "VoiRemote-edc142e008401777935788977d5196dc10d982ba", print_stdout: true,
                      env: { "DEVELOPER_DIR" => "/Library/Developer/CommandLineTools" }
  end

  installer script: {
    executable: "VoiRemote-edc142e008401777935788977d5196dc10d982ba/scripts/install-cask-app.sh",
    args: ["#{appdir}/VoiRemote.app", "edc142e008401777935788977d5196dc10d982ba"],
  }
  binary "VoiRemote-edc142e008401777935788977d5196dc10d982ba/packaging/homebrew/voiremote"

  postflight_steps do
    remove ["VoiRemote-edc142e008401777935788977d5196dc10d982ba/.build", "VoiRemote-edc142e008401777935788977d5196dc10d982ba/.swiftpm"], recursive: true
  end

  uninstall quit: "dev.voiremote.app",
            script: {
              executable: "VoiRemote-edc142e008401777935788977d5196dc10d982ba/scripts/uninstall-cask-app.sh",
              args: ["#{appdir}/VoiRemote.app", "edc142e008401777935788977d5196dc10d982ba"],
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
