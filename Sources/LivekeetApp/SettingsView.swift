import LivekeetCore
import Sparkle
import SwiftUI

private enum ModelSelection: Hashable {
    case preset(String)
    case custom
}

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    let updater: SPUUpdater

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

            updatesTab
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
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
                modelPicker(settings: settings)
            }
        }
        .formStyle(.grouped)
    }

    private func modelPicker(settings: Bindable<AppSettings>) -> some View {
        let matched = ModelCatalog.descriptor(for: self.settings.defaultModel)
        let selection: ModelSelection = matched.map { .preset($0.id) } ?? .custom

        return VStack(alignment: .leading, spacing: 6) {
            Picker("Default model", selection: Binding<ModelSelection>(
                get: { selection },
                set: { newValue in
                    if case .preset(let id) = newValue {
                        self.settings.defaultModel = id
                    }
                }
            )) {
                ForEach(ModelCatalog.availableModels) { model in
                    Text(model.displayName).tag(ModelSelection.preset(model.id))
                }
                Text("Custom…").tag(ModelSelection.custom)
            }

            if let matched {
                Text("\(matched.subtitle) · \(matched.sizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Custom model id")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Hugging Face model id", text: settings.defaultModel)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Models are downloaded automatically on first use.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func advancedTab(settings: Bindable<AppSettings>) -> some View {
        Form {
            Section("Audio") {
                Toggle("Dump audio to disk", isOn: settings.dumpAudio)
                Text("Save raw audio chunks alongside the transcript for debugging.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI Correction") {
                Toggle("Enable correction (uses Claude Haiku)", isOn: settings.enableCorrection)
                Text("Sends recent transcript segments to the Anthropic API via the claude-runner sidecar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Model", text: settings.correctionModel)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!self.settings.enableCorrection)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Correction prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: settings.correctionPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .border(Color.secondary.opacity(0.3))
                        .disabled(!self.settings.enableCorrection)
                    HStack {
                        Spacer()
                        Button("Reset to default") {
                            self.settings.correctionPrompt = CorrectionPromptBuilder.defaultBasePrompt
                        }
                        .disabled(!self.settings.enableCorrection)
                    }
                }
            }

            Section("Diagnostics") {
                Toggle("Debug mode", isOn: settings.debugMode)
                Text("Show pipeline stats panel while recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var updatesTab: some View {
        Form {
            Section("Software Update") {
                CheckForUpdatesView(updater: updater)
                    .buttonStyle(.borderedProminent)

                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
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
