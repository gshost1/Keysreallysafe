# Cask "keysrs" for our own tap, gshost1/homebrew-keysrs. The tap is
# unpublished: no repository exists and nothing has been pushed, so this file
# waits in the checkout and nothing in the repo runs brew. The sha256 :no is a
# placeholder; scripts/prepare-release.py rewrites it (and the version line)
# from the release DMG at release time — see docs/release.md.
cask "keysrs" do
  version "0.14.0"
  sha256 :no

  # The frozen DMG name and the versioned release-download URL the app's own
  # updater fixtures pin; Keysrs tags are the version with a v.
  url "https://github.com/gshost1/Keysreallysafe/releases/download/v#{version}/Keysrs-arm64.dmg"
  name "Keysrs"
  desc "Local Mac usage meter and API-key vault"
  homepage "https://keysrs.com"

  # macOS 14+ is the supported range (CLAUDE.md).
  depends_on macos: ">= :sonoma"

  # The app updates itself in place (Check for Updates, 0.11.0+), which is the
  # canonical update path; brew upgrade needs --greedy to force one anyway.
  auto_updates true
  app "Keysrs.app"
  # The one-binary CLI. A symlinked launch is the app's own documented CLI
  # path: app mode resolves through the symlink and re-execs the real bundle
  # (AppResources.applicationBundle), and the app's repair logic only repoints
  # a ~/.local/bin/keys that pointed at the retired 0.9.x runtime, so it
  # never touches this link.
  binary "#{appdir}/Keysrs.app/Contents/MacOS/keys"

  # Trash-only, matching the frozen paths CLAUDE.md names.
  zap trash: [
    # The whole Keysreallysafe tree: catalog.db, control.json, menubar.log,
    # relay.lock, imports/, backups/, .previous/ (and .previous-<uuid>
    # staging) and the retired 0.9.x runtime dirs bin/, Web/, Fixtures/,
    # Plugins/, scripts/.
    "~/Library/Application Support/Keysreallysafe",
    # The legacy launchd agent com.keysreallysafe.menubar 0.9.x installed.
    "~/Library/LaunchAgents/com.keysreallysafe.menubar.plist",
    # The app's own CLI symlink (Install Command Line Tool).
    "~/.local/bin/keys",
    # The status-item autosave position is the only UserDefaults residue; the
    # cask DSL removes defaults at file level, and this domain holds nothing
    # else of Keysrs'.
    "~/Library/Preferences/com.keysreallysafe.keysrs.plist",
    # Updater swap leftovers beside the app (AppUpdater's incoming and
    # previous names, swept on launch but left if the helper died).
    "#{appdir}/.Keysrs.app.incoming",
    "#{appdir}/.Keysrs.app.previous",
  ]
end
