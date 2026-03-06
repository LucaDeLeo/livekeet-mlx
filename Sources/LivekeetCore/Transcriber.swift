import Foundation
import MLX
import MLXAudioSTT
import MLXAudioVAD

// MARK: - Transcript Segment

public struct TranscriptSegment: Sendable {
    public let offsetSeconds: Float   // seconds from recording start
    public let text: String
    public let channel: String        // "mic" or "system"
    public let timestamp: String      // formatted "HH:mm:ss"
    public let startTime: Date
    public let speakerIndex: Int      // raw model index (0-3)
    public let speaker: String        // resolved speaker name
}

struct SpeakerKey: Hashable {
    let channel: String
    let speakerIndex: Int
}

// MARK: - Transcript Event

public enum TranscriptEvent: Sendable {
    case segment(TranscriptSegment)
    case rewrite([TranscriptSegment])
}

// MARK: - Disk-Backed PCM Storage

/// Append-only raw Float32 PCM file for incremental audio storage on disk.
/// Prevents unbounded memory growth during long recording sessions.
final class AppendablePCM {
    let url: URL
    private let fileHandle: FileHandle
    private(set) var sampleCount: Int = 0

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: url)
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        samples.withUnsafeBytes { buffer in
            fileHandle.write(Data(buffer))
        }
        sampleCount += samples.count
    }

    var audioSeconds: Double {
        Double(sampleCount) / 16000.0
    }

    func readAll() throws -> [Float] {
        fileHandle.synchronizeFile()
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    func readRange(from startSample: Int, count: Int) throws -> [Float] {
        fileHandle.synchronizeFile()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        handle.seek(toFileOffset: UInt64(startSample * MemoryLayout<Float>.size))
        guard let data = try handle.read(upToCount: count * MemoryLayout<Float>.size) else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func cleanup() {
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Transcription Work Item

private struct TranscriptionWorkItem: Sendable {
    let segment: DetectedSegment
    let channel: String
    let segmentNumber: Int
}

// MARK: - Transcriber

/// Main pipeline orchestrator: AudioCapture → SpeechDetector (Sortformer) → Parakeet → MarkdownWriter.
public actor Transcriber {
    private let capture: AudioCapture
    private let micDetector: SpeechDetector?
    private let sysDetector: SpeechDetector?
    private nonisolated(unsafe) let sttModel: any STTGenerationModel
    private let writer: MarkdownWriter
    private let config: LivekeetConfig
    private var isStopped = false
    private var segmentCounter = 0
    private let audioDumpDir: URL?

    // Transcription work queue — decouples STT inference from audio loop
    private let transcriptionStream: AsyncStream<TranscriptionWorkItem>
    private let transcriptionContinuation: AsyncStream<TranscriptionWorkItem>.Continuation
    private var pendingTranscriptionCount = 0

    // Batch diarization — audio stored on disk to avoid unbounded memory growth
    private let micPCM: AppendablePCM
    private let sysPCM: AppendablePCM
    private let pcmTempDir: URL
    private var transcriptSegments: [TranscriptSegment] = []
    private var recordingStartTime: Date?
    private let sortformerModel: SortformerModel
    private var batchPassCount = 0
    private var speakerRenames: [SpeakerKey: String] = [:]

    // Incremental batch diarization state
    private var batchMicState: StreamingState?
    private var batchSysState: StreamingState?
    private var micPCMLastBatchOffset: Int = 0
    private var sysPCMLastBatchOffset: Int = 0
    private var batchMicTurns: [DiarizationSegment] = []
    private var batchSysTurns: [DiarizationSegment] = []

    // Event stream for UI consumers
    private let eventStream: AsyncStream<TranscriptEvent>
    private let eventContinuation: AsyncStream<TranscriptEvent>.Continuation

    // Status tracking
    private let startTime = Date()
    private var lastAudioTime: Date?
    private var noAudioWarned = false
    private let noAudioWarningSeconds: TimeInterval = 10
    private let statusInterval: TimeInterval = 10

    /// Stream of transcript events. Safe to access from any isolation domain.
    public nonisolated var events: AsyncStream<TranscriptEvent> { eventStream }

    public init(config: LivekeetConfig, outputArg: String? = nil) async throws {
        let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation

        self.config = config
        self.capture = AudioCapture(micOnly: config.micOnly, systemOnly: config.systemOnly)

        // Load STT model (auto-detect type from model name)
        let modelName = config.modelName
        let shortName = modelName.split(separator: "/").last.map(String.init) ?? modelName
        Log.info("Loading \(shortName)...")
        let lowered = modelName.lowercased()
        if lowered.contains("qwen") && lowered.contains("asr") {
            self.sttModel = try await Qwen3ASRModel.fromPretrained(modelName)
        } else if lowered.contains("voxtral") {
            self.sttModel = try await VoxtralRealtimeModel.fromPretrained(modelName)
        } else {
            self.sttModel = try await ParakeetModel.fromPretrained(modelName)
        }
        Log.info("STT model ready")

        // Load Sortformer diarization model (single shared instance — stateless weights)
        Log.info("Loading speaker diarization model...")
        let sortformerModel = try await SortformerModel.fromPretrained("mlx-community/diar_sortformer_4spk-v1-fp32")
        self.sortformerModel = sortformerModel
        self.micDetector = config.systemOnly ? nil : SpeechDetector(model: sortformerModel)
        self.sysDetector = config.micOnly ? nil : SpeechDetector(model: sortformerModel)
        Log.info("Diarization model ready")

        // Resolve output path
        let outputPath = resolveOutputPath(arg: outputArg, config: config)
        let (uniquePath, wasSuffixed) = ensureUniquePath(outputPath)
        if wasSuffixed {
            Log.info("Output exists; saving to \(uniquePath.lastPathComponent)")
        }
        self.writer = try MarkdownWriter(path: uniquePath)

        if config.dumpAudio {
            let dumpDir = uniquePath.deletingPathExtension().appendingPathExtension("audio")
            try FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
            self.audioDumpDir = dumpDir
            Log.info("Audio dump: \(dumpDir.path)")
        } else {
            self.audioDumpDir = nil
        }

        // Disk-backed PCM storage for batch diarization
        let pcmDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("livekeet_pcm_\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: pcmDir, withIntermediateDirectories: true)
        self.pcmTempDir = pcmDir
        self.micPCM = try AppendablePCM(url: pcmDir.appendingPathComponent("mic.pcm"))
        self.sysPCM = try AppendablePCM(url: pcmDir.appendingPathComponent("sys.pcm"))

        // Transcription work queue
        let (tStream, tContinuation) = AsyncStream<TranscriptionWorkItem>.makeStream(
            bufferingPolicy: .bufferingNewest(10)
        )
        self.transcriptionStream = tStream
        self.transcriptionContinuation = tContinuation

        // Cap MLX buffer cache to prevent unbounded growth across inference calls.
        // Model weights are "active" memory, unaffected by cache limit.
        Memory.cacheLimit = 256 * 1024 * 1024  // 256 MB

        Log.info("Output: \(uniquePath.path)")
    }

    // MARK: - Run

    /// Main loop — blocks until stopped via Ctrl+C or `stop()`.
    public func run() async throws {
        let audioStream = try await capture.start()

        if config.systemOnly {
            let others = config.otherNames.isEmpty ? config.otherName : config.otherNames.joined(separator: ", ")
            print("Recording (system-only: \(others))")
        } else if config.micOnly {
            print("Recording (mic-only)")
        } else {
            let others = config.otherNames.isEmpty ? config.otherName : config.otherNames.joined(separator: ", ")
            print("Recording (\(config.speakerName) / \(others))")
        }
        print("Press Ctrl+C to stop\n")

        // Process audio chunks with concurrent status monitoring
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.statusWorker()
            }

            group.addTask {
                await self.noAudioMonitor()
            }

            group.addTask {
                await self.batchDiarizationWorker()
            }

            group.addTask {
                await self.transcriptionWorker()
            }

            group.addTask {
                for await chunk in audioStream {
                    let stopped = await self.isStopped
                    if stopped { break }
                    await self.processChunk(chunk)
                }
                // Audio loop done — flush detectors and drain transcription queue
                await self.flushAndFinishTranscriptions()
            }
        }

        // Final batch diarization pass
        Log.info("Running final speaker analysis...")
        await runBatchDiarization(final: true)

        await writer.writeFooter()
        await capture.stop()

        // Clean up disk-backed PCM files
        micPCM.cleanup()
        sysPCM.cleanup()
        try? FileManager.default.removeItem(at: pcmTempDir)

        eventContinuation.finish()
        print("\nSaved transcript")
    }

    /// Stop the transcriber gracefully.
    public func stop() {
        isStopped = true
    }

    // MARK: - Processing

    private func processChunk(_ chunk: AudioChunk) async {
        lastAudioTime = chunk.timestamp

        // Set recording start time on first chunk
        if recordingStartTime == nil {
            recordingStartTime = chunk.timestamp
        }

        // Accumulate raw audio for batch diarization (on disk)
        micPCM.append(chunk.mic)
        if !chunk.system.isEmpty {
            sysPCM.append(chunk.system)
        }

        // Process mic channel
        if let micDetector = micDetector {
            do {
                let micSegments = try await micDetector.feed(chunk.mic, at: chunk.timestamp)
                for segment in micSegments {
                    enqueueTranscription(segment: segment, channel: "mic")
                }
            } catch {
                Log.error("Mic detection error: \(error)")
            }
        }

        // Process system channel
        if let sysDetector = sysDetector, !chunk.system.isEmpty {
            do {
                let sysSegments = try await sysDetector.feed(chunk.system, at: chunk.timestamp)
                for segment in sysSegments {
                    enqueueTranscription(segment: segment, channel: "system")
                }
            } catch {
                Log.error("System detection error: \(error)")
            }
        }
    }

    private func enqueueTranscription(segment: DetectedSegment, channel: String) {
        segmentCounter += 1
        let item = TranscriptionWorkItem(
            segment: segment, channel: channel, segmentNumber: segmentCounter
        )
        let result = transcriptionContinuation.yield(item)
        pendingTranscriptionCount += 1
        if case .dropped = result {
            pendingTranscriptionCount -= 1
            Log.warning("Transcription queue full, dropped oldest segment")
        }
    }

    private func flushAndFinishTranscriptions() async {
        do {
            if let micDetector = micDetector {
                for segment in try await micDetector.flush() {
                    enqueueTranscription(segment: segment, channel: "mic")
                }
            }
            if let sysDetector = sysDetector {
                for segment in try await sysDetector.flush() {
                    enqueueTranscription(segment: segment, channel: "system")
                }
            }
        } catch {
            Log.error("Flush error: \(error)")
        }
        transcriptionContinuation.finish()
    }

    private func transcriptionWorker() async {
        for await item in transcriptionStream {
            pendingTranscriptionCount -= 1

            // Dump audio segment as WAV for debugging
            if let dumpDir = audioDumpDir {
                let formatter = DateFormatter()
                formatter.dateFormat = "HHmmss"
                let timeStr = formatter.string(from: item.segment.startTime)
                let duration = String(format: "%.1fs", item.segment.duration)
                let filename = "\(String(format: "%03d", item.segmentNumber))_\(item.channel)_\(timeStr)_\(duration).wav"
                let wavURL = dumpDir.appendingPathComponent(filename)
                do {
                    try WAVWriter.write(samples: item.segment.audio, to: wavURL)
                } catch {
                    Log.error("Failed to dump audio: \(error)")
                }
            }

            // Skip very short segments that can cause model errors
            guard item.segment.audio.count >= 24000 else { continue }

            // Run STT inference off-actor to unblock audio processing
            let audio = item.segment.audio
            let audioDuration = item.segment.duration
            nonisolated(unsafe) let model = sttModel
            let inferenceStart = Date()

            let result = await Task.detached {
                let audioArray = MLXArray(audio)
                let output = model.generate(audio: audioArray)
                Memory.clearCache()
                return output
            }.value

            let inferenceTime = Date().timeIntervalSince(inferenceStart)
            let ratio = audioDuration / inferenceTime
            Log.info("STT inference: \(String(format: "%.1f", audioDuration))s audio in \(String(format: "%.1f", inferenceTime))s (\(String(format: "%.1f", ratio))x realtime)")

            await writeTranscriptionResult(result, segment: item.segment, channel: item.channel)
        }
    }

    private func writeTranscriptionResult(
        _ result: STTOutput, segment: DetectedSegment, channel: String
    ) async {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let speaker = resolveSpeaker(channel: channel, speakerIndex: segment.speakerIndex)

        let baseOffset: Float
        if let start = recordingStartTime {
            baseOffset = Float(segment.startTime.timeIntervalSince(start))
        } else {
            baseOffset = 0
        }

        if let sentences = result.segments, !sentences.isEmpty {
            for sentence in sentences {
                guard let sentenceText = sentence["text"] as? String,
                      let sentenceStart = sentence["start"] as? Double else { continue }
                let trimmed = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let sentenceTime = segment.startTime.addingTimeInterval(sentenceStart)
                let seg = TranscriptSegment(
                    offsetSeconds: baseOffset + Float(sentenceStart),
                    text: trimmed,
                    channel: channel,
                    timestamp: MarkdownWriter.formatTime(sentenceTime),
                    startTime: sentenceTime,
                    speakerIndex: segment.speakerIndex,
                    speaker: speaker
                )
                transcriptSegments.append(seg)
                eventContinuation.yield(.segment(seg))
                await writer.writeSegment(time: sentenceTime, speaker: speaker, text: trimmed)
            }
        } else {
            let seg = TranscriptSegment(
                offsetSeconds: baseOffset,
                text: text,
                channel: channel,
                timestamp: MarkdownWriter.formatTime(segment.startTime),
                startTime: segment.startTime,
                speakerIndex: segment.speakerIndex,
                speaker: speaker
            )
            transcriptSegments.append(seg)
            eventContinuation.yield(.segment(seg))
            await writer.writeSegment(time: segment.startTime, speaker: speaker, text: text)
        }
    }

    private func resolveSpeaker(channel: String, speakerIndex: Int) -> String {
        // 1. Check user renames
        let key = SpeakerKey(channel: channel, speakerIndex: speakerIndex)
        if let renamed = speakerRenames[key] { return renamed }

        // 2. Config defaults
        if channel == "mic" {
            if speakerIndex == 0 {
                return config.speakerName
            }
            return "Local \(speakerIndex + 1)"
        } else {
            if speakerIndex < config.otherNames.count {
                return config.otherNames[speakerIndex]
            }
            if speakerIndex == 0 {
                return config.otherName
            }
            return "Remote \(speakerIndex + 1)"
        }
    }

    // MARK: - Batch Diarization

    private func batchDiarizationWorker() async {
        // Wait 30s before first batch (checking for stop every second)
        for _ in 0..<30 {
            if isStopped { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        while !isStopped {
            await runBatchDiarization(final: false)

            // Wait 30s between batches
            for _ in 0..<30 {
                if isStopped { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func runBatchDiarization(final isFinal: Bool) async {
        guard !transcriptSegments.isEmpty else { return }

        batchPassCount += 1

        // Incrementally process only new mic audio since last batch pass
        if !config.systemOnly && micPCM.sampleCount > micPCMLastBatchOffset {
            do {
                let newCount = micPCM.sampleCount - micPCMLastBatchOffset
                let samples = try micPCM.readRange(from: micPCMLastBatchOffset, count: newCount)

                if batchMicState == nil {
                    batchMicState = sortformerModel.initStreamingState()
                }
                let (output, newState) = try await sortformerModel.feed(
                    chunk: MLXArray(samples),
                    state: batchMicState!
                )
                batchMicState = newState
                batchMicTurns.append(contentsOf: output.segments)
                micPCMLastBatchOffset = micPCM.sampleCount
                Memory.clearCache()
            } catch {
                Log.error("Batch diarization (mic) error: \(error)")
            }
        }

        // Incrementally process only new system audio since last batch pass
        if !config.micOnly && sysPCM.sampleCount > sysPCMLastBatchOffset {
            do {
                let newCount = sysPCM.sampleCount - sysPCMLastBatchOffset
                let samples = try sysPCM.readRange(from: sysPCMLastBatchOffset, count: newCount)

                if batchSysState == nil {
                    batchSysState = sortformerModel.initStreamingState()
                }
                let (output, newState) = try await sortformerModel.feed(
                    chunk: MLXArray(samples),
                    state: batchSysState!
                )
                batchSysState = newState
                batchSysTurns.append(contentsOf: output.segments)
                sysPCMLastBatchOffset = sysPCM.sampleCount
                Memory.clearCache()
            } catch {
                Log.error("Batch diarization (system) error: \(error)")
            }
        }

        let totalTurns = batchMicTurns.count + batchSysTurns.count
        await rebuildTranscript(micTurns: batchMicTurns, sysTurns: batchSysTurns)

        let passLabel = isFinal ? "final" : "pass \(batchPassCount)"
        Log.info("Speaker labels updated (\(passLabel), \(totalTurns) turns)")
    }

    private func rebuildTranscript(
        micTurns: [DiarizationSegment],
        sysTurns: [DiarizationSegment]
    ) async {
        let resolved = transcriptSegments.map { seg -> TranscriptSegment in
            let turns = seg.channel == "mic" ? micTurns : sysTurns
            let idx = resolveBatchSpeakerIndex(
                offsetSeconds: seg.offsetSeconds,
                channel: seg.channel,
                turns: turns
            )
            return TranscriptSegment(
                offsetSeconds: seg.offsetSeconds,
                text: seg.text,
                channel: seg.channel,
                timestamp: seg.timestamp,
                startTime: seg.startTime,
                speakerIndex: idx,
                speaker: resolveSpeaker(channel: seg.channel, speakerIndex: idx)
            )
        }
        // Update stored segments with resolved speakers
        transcriptSegments = resolved
        let writerSegments = resolved.map { (timestamp: $0.timestamp, speaker: $0.speaker, text: $0.text) }
        await writer.rewriteAll(segments: writerSegments)
        eventContinuation.yield(.rewrite(resolved))
    }

    private func resolveBatchSpeakerIndex(
        offsetSeconds: Float,
        channel: String,
        turns: [DiarizationSegment]
    ) -> Int {
        // 1. Find containing turn
        for turn in turns {
            if offsetSeconds >= turn.start && offsetSeconds <= turn.end {
                return turn.speaker
            }
        }

        // 2. Find closest turn midpoint within 2 seconds
        var bestDistance: Float = .infinity
        var bestSpeaker: Int?
        for turn in turns {
            let midpoint = (turn.start + turn.end) / 2
            let distance = abs(offsetSeconds - midpoint)
            if distance < 2.0 && distance < bestDistance {
                bestDistance = distance
                bestSpeaker = turn.speaker
            }
        }
        if let speaker = bestSpeaker {
            return speaker
        }

        // 3. Fall back to default index
        return 0
    }

    // MARK: - Speaker Renaming

    public func renameSpeaker(channel: String, speakerIndex: Int, newName: String) async {
        let key = SpeakerKey(channel: channel, speakerIndex: speakerIndex)
        if newName.isEmpty {
            speakerRenames.removeValue(forKey: key)
        } else {
            speakerRenames[key] = newName
        }

        // Re-resolve all segments, rewrite file, notify UI
        transcriptSegments = transcriptSegments.map { seg in
            TranscriptSegment(
                offsetSeconds: seg.offsetSeconds, text: seg.text, channel: seg.channel,
                timestamp: seg.timestamp, startTime: seg.startTime,
                speakerIndex: seg.speakerIndex,
                speaker: resolveSpeaker(channel: seg.channel, speakerIndex: seg.speakerIndex)
            )
        }
        let writerSegments = transcriptSegments.map { (timestamp: $0.timestamp, speaker: $0.speaker, text: $0.text) }
        await writer.rewriteAll(segments: writerSegments)
        eventContinuation.yield(.rewrite(transcriptSegments))
    }

    // MARK: - Status Workers

    private func statusWorker() async {
        var nextStatus = Date().addingTimeInterval(statusInterval)
        while !isStopped {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Date() >= nextStatus {
                let snap = Memory.snapshot()
                let activeMB = snap.activeMemory / (1024 * 1024)
                let cacheMB = snap.cacheMemory / (1024 * 1024)
                let micOvf = capture.micBuffer.overflows
                let sysOvf = capture.systemBuffer.overflows
                Log.info("Status: active=\(activeMB)MB cache=\(cacheMB)MB segments=\(transcriptSegments.count) pending=\(pendingTranscriptionCount) micOvf=\(micOvf.count)/\(micOvf.samples)smp sysOvf=\(sysOvf.count)/\(sysOvf.samples)smp")
                nextStatus = Date().addingTimeInterval(statusInterval)
            }
        }
    }

    private func noAudioMonitor() async {
        // Early check: warn quickly if mic permission was denied
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if !isStopped && capture.micPermissionDenied && !noAudioWarned {
            noAudioWarned = true
            Log.warning("Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone.")
        }

        while !isStopped {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !noAudioWarned && lastAudioTime == nil {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed >= noAudioWarningSeconds {
                    noAudioWarned = true
                    if config.micOnly {
                        Log.warning("No audio detected. Check microphone permission.")
                    } else if config.systemOnly {
                        Log.warning("No audio detected. Check Screen Recording permission.")
                    } else {
                        Log.warning("No audio detected. Check Screen Recording permission or try --mic-only.")
                    }
                }
            }
        }
    }
}
