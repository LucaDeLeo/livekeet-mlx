import SwiftUI

@main
struct LivekeetApp: App {
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
        }
        .defaultSize(width: 700, height: 500)

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}
