import AppKit
import PlinthApp
import Sparkle

// Entry point for the Xcode app target. All of Plinth lives in the Swift package; this target
// adds the app bundle and Sparkle auto-updates.
//
// The updater starts only when the build carries a Sparkle public key (SUPublicEDKey), which
// Scripts/release.sh injects for signed releases. Local and CI builds have none, so they never
// check for updates.
let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
let updater: SPUStandardUpdaterController? = publicKey.isEmpty ? nil
    : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

PlinthLauncher.run(checkForUpdates: updater.map { controller in { controller.checkForUpdates(nil) } })
