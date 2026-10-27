import AppKit
import Sparkle

/// Sparkle bridge. Feed URL and EdDSA public key live in the bundle's
/// Info.plist (SUFeedURL / SUPublicEDKey), so bare .build runs — which have no
/// bundle — start with the updater off, matching the other bundle-dependent
/// features (login item, notifications).
@MainActor
final class UpdatesController {
    private let controller: SPUStandardUpdaterController?

    init() {
        guard Bundle.main.bundleIdentifier != nil else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }
}
