# Homebrew cask for Cybokron Player Identity (spec §41).
# `version` and `sha256` are updated by scripts/update-cask.sh from the release asset
# (scripts/release.sh runs it after packaging; the release workflow commits the result).
cask "player-identity" do
  version "2.17.1"
  sha256 "68a4e7a5189b8a5f432146e2867a6c9d36c3604f2d71396b2bf59e39115d3110"

  url "https://github.com/ercanatay/player-identity/releases/download/v#{version}/PlayerIdentity-#{version}-macos.zip"
  name "Cybokron Player Identity"
  desc "Shows the Xash3D player identity, CIDs and server bans"
  homepage "https://github.com/ercanatay/player-identity"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "PlayerIdentity.app"
  binary "#{appdir}/PlayerIdentity.app/Contents/Helpers/playeridentityctl"

  zap trash: [
    "~/Library/Application Support/tr.ercanatay.playeridentity",
    "~/Library/Preferences/tr.ercanatay.playeridentity.plist",
  ]
end
