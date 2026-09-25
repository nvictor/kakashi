import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    // Local builds have no public key, so the updater stays idle until a release build injects one.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var canCheckForUpdates: Bool { updaterController.updater.canCheckForUpdates }

    func checkForUpdates() { updaterController.checkForUpdates(nil) }
}
