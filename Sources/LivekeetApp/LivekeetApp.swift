import LivekeetCore
import Sparkle
import SwiftUI

@main
struct LivekeetApp: App {
    @State private var settings = AppSettings()
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Prewarm STT + diarization in the background so the first "Start Recording"
        // click is instant (or very close to it). Reads current settings via a fresh
        // AppSettings — UserDefaults-backed — and captures only the resulting values.
        let bootstrap = AppSettings()
        let modelName = bootstrap.defaultModel
        let diarEnabled = !bootstrap.disableDiarization
        Task.detached(priority: .utility) {
            await ModelPrewarmer.shared.startPrewarm(
                sttModelName: modelName,
                diarization: diarEnabled
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
        }
        .defaultSize(width: 700, height: 500)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            SettingsView(updater: updaterController.updater)
                .environment(settings)
        }
    }
}

struct CheckForUpdatesView: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel

    let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self._viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates...") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
