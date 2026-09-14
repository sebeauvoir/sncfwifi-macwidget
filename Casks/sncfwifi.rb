cask "sncfwifi" do
  version :latest
  sha256 :no_check

  url "https://github.com/antvgr/sncfwifi-macwidget/releases/latest/download/SNCFWifi.zip"
  name "SNCFWifi"
  desc "Menu bar widget showing real-time TGV Inoui journey info from the train WiFi API"
  homepage "https://github.com/antvgr/sncfwifi-macwidget"

  depends_on macos: :big_sur

  app "SNCFWifi.app"

  zap trash: [
    "~/Library/Caches/fr.sncf.wifi-widget",
    "~/Library/Preferences/fr.sncf.wifi-widget.plist",
    "~/Library/Saved Application State/fr.sncf.wifi-widget.savedState",
  ]

  caveats do
    <<~EOS
      SNCFWifi est signée en ad-hoc (non notarisée par Apple). macOS peut la bloquer au
      premier lancement. Pour l'autoriser :
        xattr -dr com.apple.quarantine "#{appdir}/SNCFWifi.app"
      ou faites un clic droit sur l'app dans le Finder puis « Ouvrir ».

      Ce cask tire toujours la dernière release publiée, mais sans numéro de version :
      `brew upgrade` ne détecte donc pas les nouveautés. Pour mettre à jour :
        brew reinstall --cask sncfwifi
    EOS
  end
end
