import LivekeetCore
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

                Toggle(isOn: $settings.disableDiarization) {
                    Label("No diar", systemImage: "person.slash")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(viewModel.isRecording)
                .fixedSize()

                Toggle(isOn: $settings.enableCorrection) {
                    Label("AI fix", systemImage: "wand.and.stars")
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

            // Debug stats panel
            if let stats = viewModel.debugStats, settings.debugMode {
                Divider()
                DebugStatsPanel(stats: stats)
            }

            // Status bar
            if viewModel.isLoading || viewModel.errorMessage != nil || viewModel.savedFilePath != nil {
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
                    if let path = viewModel.savedFilePath {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .onTapGesture {
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                            }
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
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
        .onChange(of: viewModel.isRecording) { _, isRecording in
            if isRecording && settings.debugMode {
                viewModel.startDebugPolling()
            } else if !isRecording {
                viewModel.stopDebugPolling()
            }
        }
        .onChange(of: settings.debugMode) { _, debugMode in
            if debugMode && viewModel.isRecording {
                viewModel.startDebugPolling()
            } else if !debugMode {
                viewModel.stopDebugPolling()
            }
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

// MARK: - Debug Stats Panel

struct DebugStatsPanel: View {
    let stats: DebugStats

    var body: some View {
        HStack(spacing: 12) {
            statItem(stats.pipelineState, icon: pipelineIcon, color: pipelineColor)
            divider
            if let age = stats.secondsSinceLastAudio {
                statItem(formatAge(age), icon: "waveform", color: age > 5 ? .red : .secondary)
            } else {
                statItem("No audio", icon: "waveform", color: .red)
            }
            divider
            statItem("\(stats.pendingTranscriptions) pending", icon: "text.bubble", color: stats.pendingTranscriptions > 3 ? .orange : .secondary)
            divider
            if let dur = stats.lastInferenceAudioDuration, let ratio = stats.lastInferenceRatio {
                statItem(String(format: "%.1fs @ %.1fx", dur, ratio), icon: "brain", color: ratio < 1.0 ? .red : .secondary)
            } else {
                statItem("-- STT", icon: "brain", color: .secondary)
            }
            divider
            statItem("\(stats.mlxActiveMemoryMB)/\(stats.mlxCacheMemoryMB) MB", icon: "memorychip", color: .secondary)
            divider
            let ovf = stats.micOverflowCount + stats.systemOverflowCount
            statItem("\(ovf) ovf", icon: "exclamationmark.triangle", color: ovf > 0 ? .orange : .secondary)
            divider
            statItem("\(stats.totalSegments) seg", icon: "doc.text", color: .secondary)
            Spacer()
        }
        .font(.system(.caption2, design: .monospaced))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var divider: some View {
        Divider().frame(height: 12)
    }

    private func statItem(_ label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(color)
            Text(label).foregroundStyle(color)
        }
    }

    private var pipelineIcon: String {
        switch stats.pipelineState {
        case "Recording": "record.circle"
        case "Processing": "gearshape.2"
        case "Stuck?": "exclamationmark.triangle.fill"
        case "Waiting for audio": "ear"
        default: "pause.circle"
        }
    }

    private var pipelineColor: Color {
        switch stats.pipelineState {
        case "Recording": .green
        case "Processing": .blue
        case "Stuck?": .red
        case "Waiting for audio": .orange
        default: .secondary
        }
    }

    private func formatAge(_ seconds: Double) -> String {
        if seconds < 1 { return "<1s ago" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        return "\(Int(seconds / 60))m ago"
    }
}
