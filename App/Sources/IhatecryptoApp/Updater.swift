import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Updates for the copy downloaded from the site (release.sh). Sparkle reads the site's appcast once a day, checks each
/// update's EdDSA signature and the feed's, and downloads a new version by itself; once it's all there the app menu and
/// the menu bar's popover say «Restart to update to N» (a notification too), and it installs at that restart or at quit. A copy built on this Mac has no feed
/// (SUFeedURL is empty) and never looks. «check for updates» in the chat or the app menu looks now.
/// `swift run` has no Sparkle and no bundle: nothing here runs there.
final class Updater: NSObject {
    static let shared = Updater()
    private weak var workspace: Workspace?
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif
    /// Installs the downloaded version now and opens the app again: Sparkle's own call.
    private var installNow: (() -> Void)?

    /// A feed and a key in the app's plist: this copy updates itself.
    var available: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return !(info["SUFeedURL"] as? String ?? "").isEmpty && !(info["SUPublicEDKey"] as? String ?? "").isEmpty
    }

    func start(_ ws: Workspace) {
        guard available else { return }
        workspace = ws
        // Paused for the last update's install (below); a local build never pauses it, so it never resumes it either.
        KeepRunning.resume()
        #if canImport(Sparkle)
        if controller == nil {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
            // Downloaded in the background; nothing installs before a restart.
            controller?.updater.automaticallyChecksForUpdates = true
            controller?.updater.automaticallyDownloadsUpdates = true
        }
        #endif
    }

    /// «Restart to update»: the downloaded version goes in and the app opens again.
    func restartToUpdate() { installNow?() }

    /// Sparkle's window: «You're up to date», or the new version with its notes and Install.
    func check() {
        #if canImport(Sparkle)
        NSApp.activate()
        controller?.checkForUpdates(nil)
        #endif
    }
}

#if canImport(Sparkle)
extension Updater: @preconcurrency SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    /// The keep-running agent could open the old copy while Sparkle swaps it: it rests until the new copy starts.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { KeepRunning.pause() }

    /// The new version is downloaded whole: the menus offer the restart, and a notification says so once.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        guard let ws = workspace, ws.updateReady != item.displayVersionString else { return true }
        ws.updateReady = item.displayVersionString
        ws.notify(.update, ws.say("ihatecrypto \(item.displayVersionString) is downloaded", "ihatecrypto \(item.displayVersionString) скачана"),
                  ws.say("Restart to update: in the app menu or the menu bar's coin.", "Перезапусти, чтобы обновиться: в меню приложения или у монеты в строке меню."), record: false)
        return true
    }

    /// In the background (menu bar, window closed) no window jumps up: a notification says an update is ready, and its
    /// click brings Sparkle's window (NoticeDelegate).
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated, let ws = workspace else { return }
        ws.notify(.update, ws.say("ihatecrypto \(update.displayVersionString) is ready", "Готова ihatecrypto \(update.displayVersionString)"),
                  ws.say("Click to see what's new and install it.", "Нажми, чтобы посмотреть, что нового, и установить."), record: false)
    }
}
#endif
