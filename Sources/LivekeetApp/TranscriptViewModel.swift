import Foundation
import LivekeetCore
import Observation

struct DisplaySegment: Identifiable {
    let id: Int
    let timestamp: String
    let speaker: String
    let text: String
    let channel: String
    let speakerIndex: Int
}

@Observable
@MainActor
final class TranscriptViewModel {
    var segments: [DisplaySegment] = []
    var isRecording = false
    var isLoading = false
    var errorMessage: String?
    var savedFilePath: String?

    // Rename state
    var renamingChannel: String?
    var renamingSpeakerIndex: Int?
    var renameText: String = ""
    var isShowingRename = false

    private var transcriber: Transcriber?
    private nonisolated(unsafe) var eventTask: Task<Void, Never>?
    private nonisolated(unsafe) var runTask: Task<Void, Never>?

    func startRecording(config: LivekeetConfig) {
        guard !isRecording else { return }
        isRecording = true
        isLoading = true
        errorMessage = nil
        savedFilePath = nil
        segments = []

        // Cancel any lingering tasks from a previous session
        eventTask?.cancel()
        eventTask = nil
        runTask?.cancel()
        runTask = nil

        runTask = Task {
            do {
                let t = try await Transcriber(config: config)
                self.transcriber = t

                // Start consuming events before run() so we don't miss any
                eventTask = Task {
                    for await event in t.events {
                        self.handleEvent(event)
                    }
                }

                self.isLoading = false

                try await t.run()
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                self.isRecording = false
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isLoading = false
        Task {
            await transcriber?.stop()
            eventTask?.cancel()
            eventTask = nil
            runTask?.cancel()
            runTask = nil
        }
    }

    func beginRename(channel: String, speakerIndex: Int, currentName: String) {
        renamingChannel = channel
        renamingSpeakerIndex = speakerIndex
        renameText = currentName
        isShowingRename = true
    }

    func confirmRename() {
        guard let ch = renamingChannel, let idx = renamingSpeakerIndex else { return }
        isShowingRename = false
        Task { await transcriber?.renameSpeaker(channel: ch, speakerIndex: idx, newName: renameText) }
    }

    private func handleEvent(_ event: TranscriptEvent) {
        switch event {
        case .segment(let seg):
            segments.append(DisplaySegment(
                id: segments.count,
                timestamp: seg.timestamp,
                speaker: seg.speaker,
                text: seg.text,
                channel: seg.channel,
                speakerIndex: seg.speakerIndex
            ))
        case .rewrite(let newSegments):
            segments = newSegments.enumerated().map { index, seg in
                DisplaySegment(
                    id: index,
                    timestamp: seg.timestamp,
                    speaker: seg.speaker,
                    text: seg.text,
                    channel: seg.channel,
                    speakerIndex: seg.speakerIndex
                )
            }
        case .completed(let path):
            savedFilePath = path
        }
    }

    deinit {
        eventTask?.cancel()
        runTask?.cancel()
    }
}
