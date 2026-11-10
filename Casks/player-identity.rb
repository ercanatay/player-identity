# Homebrew cask for Player Identity (spec §41).
# `version` and `sha256` are updated by scripts/update-cask.sh from the release asset
# (scripts/release.sh runs it after packaging; the release workflow commits the result).
cask "player-identity" do
  version "2.6.0"
  sha256 "cdfb8d76fda8b460dcc9e3fbea95e6503ad83bd4ef6c99769883fd7d9bd2b646"

  url "https://github.com/ercanatay/player-identity/releases/download/v#{version}/PlayerIdentity-#{version}-macos.zip"
  name "Player Identity"
  desc "Shows the Xash3D player identity, CIDs and server bans"
  homepage "https://github.com/ercanatay/player-identity"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "PlayerIdentity.app"
  binary "#{appdir}/PlayerIdentity.app/Contents/Helpers/playeridentityctl"

  zap trash: [
    "~/Library/Application Support/tr.ercanatay.playeridentity",
    "~/Library/Preferences/tr.ercanatay.playeridentity.plist",
  ]
end
