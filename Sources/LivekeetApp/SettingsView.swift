import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        TabView {
            generalTab(settings: $settings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            advancedTab(settings: $settings)
                .tabItem {
                    Label("Advanced", systemImage: "wrench")
                }
        }
        .frame(width: 460)
    }

    private func generalTab(settings: Bindable<AppSettings>) -> some View {
        Form {
            Section("Speakers") {
                TextField("Your name", text: settings.speakerName)
                    .textFieldStyle(.roundedBorder)
                Text("How you appear in the transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Other speakers", text: settings.otherNames)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated names for remote participants.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                HStack {
                    TextField("Output directory", text: settings.outputDirectory)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose...") {
                        chooseOutputDirectory()
                    }
                }
                Text("Transcripts save to: \(self.settings.resolvedOutputDirectory)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Filename pattern", text: settings.filenamePattern)
                    .textFieldStyle(.roundedBorder)
                Text("Placeholders: {date}, {time}, {datetime}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                TextField("Default model", text: settings.defaultModel)
                    .textFieldStyle(.roundedBorder)
                Text("Downloaded automatically on first use. English: parakeet-tdt-0.6b-v2, Multilingual: parakeet-tdt-0.6b-v3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func advancedTab(settings: Bindable<AppSettings>) -> some View {
        Form {
            Section("Audio") {
                Toggle("Dump audio to disk", isOn: settings.dumpAudio)
                Text("Save raw audio chunks alongside the transcript for debugging.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save transcripts"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDirectory = url.path
        }
    }
}
