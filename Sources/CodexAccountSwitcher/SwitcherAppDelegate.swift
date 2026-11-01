import AppKit
import Combine

@MainActor
final class SwitcherAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.live()
    let updater = AppUpdater()
    let tiboForecast = TiboForecastModel()
    let apiUsage = APIUsageModel(demo: APIAppMode.isDemo)
    var reopenAPIWindow: (() -> Void)?

    private var modelObservation: AnyCancellable?
    private var wakeObservation: AnyCancellable?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopenAPIWindow?() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        apiUsage.start()
        // The independent API build starts without accessing any Codex credentials.
        guard !APIAppMode.usesIsolatedStartup else { return }
        modelObservation = model.objectWillChange.sink { [weak self] in
            guard let self else { return }
            updater.accountOperationInProgress = model.isMutating || model.isAddingAccount
        }
        updater.start()
        tiboForecast.start()
        wakeObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.model.refreshWeeklyUsage() }
            }
        Task { await model.startBackgroundUsageRefresh() }
    }
}
