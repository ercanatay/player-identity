# Homebrew cask for Player Identity (spec §41).
# `version` and `sha256` are updated by scripts/update-cask.sh from the release asset
# (scripts/release.sh runs it after packaging; the release workflow commits the result).
cask "player-identity" do
  version "2.10.2"
  sha256 "5c373ff61c7d5c03ee9b5a95aea54fceefa7e062706d0ff89aceae5b66591a36"

  url "https://github.com/ercanatay/player-identity/releases/download/v#{version}/PlayerIdentity-#{version}-macos.zip"
  name "Player Identity"
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
