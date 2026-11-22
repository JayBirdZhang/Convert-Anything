import Observation
import Sparkle

/// Updates through Sparkle. The feed address and the public signing key are in Support/Info.plist; new
/// versions are announced in an appcast.xml attached to the latest GitHub release.
@Observable final class Updates {
    static let shared = Updates()

    @ObservationIgnored private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var updater: SPUUpdater { controller.updater }

    /// Looks for a new version about once a day and offers to install it.
    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.checksAutomatically) { updater.automaticallyChecksForUpdates = newValue }
        }
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Checks right away and says what it found, even when it's already up to date.
    func checkNow() {
        controller.checkForUpdates(nil)
    }
}
