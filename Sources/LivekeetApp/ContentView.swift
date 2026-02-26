import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @State private var viewModel = TranscriptViewModel()

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Other speakers", text: $settings.otherNames)
                        .textFieldStyle(.plain)
                        .disabled(viewModel.isRecording)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                Toggle(isOn: $settings.micOnly) {
                    Label("Mic only", systemImage: "mic.fill")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(viewModel.isRecording)
                .fixedSize()

                Toggle(isOn: $settings.systemOnly) {
                    Label("System only", systemImage: "speaker.wave.2.fill")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(viewModel.isRecording)
                .fixedSize()

                Toggle(isOn: $settings.multilingual) {
                    Label("Multi", systemImage: "globe")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(viewModel.isRecording)
                .fixedSize()

                Spacer()

                SettingsLink {
                    Image(systemName: "gear")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                recordButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Transcript
            ZStack {
                Color(nsColor: .textBackgroundColor)

                if viewModel.segments.isEmpty && !viewModel.isLoading && viewModel.errorMessage == nil {
                    VStack(spacing: 8) {
                        Image(systemName: viewModel.isRecording ? "waveform" : "mic.badge.plus")
                            .font(.system(size: 32, weight: .thin))
                            .foregroundStyle(.tertiary)
                        Text(viewModel.isRecording ? "Waiting for speech..." : "Press Record to start")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    TranscriptView(segments: viewModel.segments) { channel, speakerIndex, currentName in
                        viewModel.beginRename(channel: channel, speakerIndex: speakerIndex, currentName: currentName)
                    }
                }
            }

            // Status bar
            if viewModel.isLoading || viewModel.errorMessage != nil {
                Divider()
                HStack(spacing: 8) {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading models...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = viewModel.errorMessage {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .alert("Rename Speaker", isPresented: $viewModel.isShowingRename) {
            TextField("Name", text: $viewModel.renameText)
            Button("Rename") { viewModel.confirmRename() }
            Button("Cancel", role: .cancel) { }
        }
        .frame(minWidth: 520, minHeight: 350)
    }

    private var recordButton: some View {
        Button(action: {
            if viewModel.isRecording {
                viewModel.stopRecording()
            } else {
                viewModel.startRecording(config: settings.buildConfig())
            }
        }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isRecording ? Color.red : Color.red.opacity(0.6))
                    .frame(width: 10, height: 10)
                    .overlay {
                        if viewModel.isRecording {
                            Circle()
                                .fill(.red.opacity(0.4))
                                .frame(width: 16, height: 16)
                        }
                    }
                Text(viewModel.isRecording ? "Stop" : "Record")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                viewModel.isRecording
                    ? AnyShapeStyle(Color.red.opacity(0.1))
                    : AnyShapeStyle(.quaternary.opacity(0.5)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
    }
}
