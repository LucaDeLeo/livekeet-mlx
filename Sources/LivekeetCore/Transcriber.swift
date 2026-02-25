import Foundation
import MLX
import MLXAudioSTT
import MLXAudioVAD

// MARK: - Transcript Segment

struct TranscriptSegment {
    let offsetSeconds: Float   // seconds from recording start
    let text: String
    let channel: String        // "mic" or "system"
    let timestamp: String      // formatted "HH:mm:ss"
    let startTime: Date
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
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    func cleanup() {
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Transcriber

/// Main pipeline orchestrator: AudioCapture → SpeechDetector (Sortformer) → Parakeet → MarkdownWriter.
public actor Transcriber {
    private let capture: AudioCapture
    private let micDetector: SpeechDetector
    private let sysDetector: SpeechDetector?
    private let sttModel: any STTGenerationModel
    private let writer: MarkdownWriter
    private let config: LivekeetConfig
    private var isStopped = false
    private var segmentCounter = 0
    private let audioDumpDir: URL?

    // Batch diarization — audio stored on disk to avoid unbounded memory growth
    private let micPCM: AppendablePCM
    private let sysPCM: AppendablePCM
    private let pcmTempDir: URL
    private var transcriptSegments: [TranscriptSegment] = []
    private var recordingStartTime: Date?
    private var batchSortformerMic: SortformerModel?
    private var batchSortformerSys: SortformerModel?
    private var batchPassCount = 0

    // Status tracking
    private let startTime = Date()
    private var lastAudioTime: Date?
    private var noAudioWarned = false
    private let noAudioWarningSeconds: TimeInterval = 10
    private let statusInterval: TimeInterval = 10

    public init(config: LivekeetConfig, outputArg: String? = nil) async throws {
        self.config = config
        self.capture = AudioCapture(micOnly: config.micOnly)

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

        // Load Sortformer diarization model
        Log.info("Loading speaker diarization model...")
        let sortformerModel = try await SortformerModel.fromPretrained("mlx-community/diar_sortformer_4spk-v1-fp32")
        self.micDetector = SpeechDetector(model: sortformerModel)
        Log.info("Diarization model ready")

        if !config.micOnly {
            let sysSortformer = try await SortformerModel.fromPretrained("mlx-community/diar_sortformer_4spk-v1-fp32")
            self.sysDetector = SpeechDetector(model: sysSortformer)
        } else {
            self.sysDetector = nil
        }

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

        Log.info("Output: \(uniquePath.path)")
    }

    // MARK: - Run

    /// Main loop — blocks until stopped via Ctrl+C or `stop()`.
    public func run() async throws {
        let audioStream = try await capture.start()

        if !config.micOnly {
            let others = config.otherNames.isEmpty ? config.otherName : config.otherNames.joined(separator: ", ")
            print("Recording (\(config.speakerName) / \(others))")
        } else {
            print("Recording (mic-only)")
        }
        print("Press Ctrl+C to stop\n")

        // Process audio chunks with concurrent status monitoring
        await withTaskGroup(of: Void.self) { group in
            if config.showStatus {
                group.addTask {
                    await self.statusWorker()
                }
            }

            group.addTask {
                await self.noAudioMonitor()
            }

            group.addTask {
                await self.batchDiarizationWorker()
            }

            group.addTask {
                for await chunk in audioStream {
                    let stopped = await self.isStopped
                    if stopped { break }
                    await self.processChunk(chunk)
                }
            }
        }

        // Flush remaining segments
        do {
            for segment in try await micDetector.flush() {
                await transcribeAndWrite(segment: segment, channel: "mic")
            }
            if let sysDetector = sysDetector {
                for segment in try await sysDetector.flush() {
                    await transcribeAndWrite(segment: segment, channel: "system")
                }
            }
        } catch {
            Log.error("Flush error: \(error)")
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
        do {
            let micSegments = try await micDetector.feed(chunk.mic, at: chunk.timestamp)
            for segment in micSegments {
                await transcribeAndWrite(segment: segment, channel: "mic")
            }
        } catch {
            Log.error("Mic detection error: \(error)")
        }

        // Process system channel
        if let sysDetector = sysDetector, !chunk.system.isEmpty {
            do {
                let sysSegments = try await sysDetector.feed(chunk.system, at: chunk.timestamp)
                for segment in sysSegments {
                    await transcribeAndWrite(segment: segment, channel: "system")
                }
            } catch {
                Log.error("System detection error: \(error)")
            }
        }
    }

    private func transcribeAndWrite(segment: DetectedSegment, channel: String) async {
        segmentCounter += 1
        let segNum = segmentCounter

        // Dump audio segment as WAV for debugging
        if let dumpDir = audioDumpDir {
            let formatter = DateFormatter()
            formatter.dateFormat = "HHmmss"
            let timeStr = formatter.string(from: segment.startTime)
            let duration = String(format: "%.1fs", segment.duration)
            let filename = "\(String(format: "%03d", segNum))_\(channel)_\(timeStr)_\(duration).wav"
            let wavURL = dumpDir.appendingPathComponent(filename)
            do {
                try WAVWriter.write(samples: segment.audio, to: wavURL)
            } catch {
                Log.error("Failed to dump audio: \(error)")
            }
        }

        // Skip very short segments that can cause model errors (especially Qwen3-ASR)
        guard segment.audio.count >= 24000 else { return }  // minimum 1.5 seconds at 16kHz

        let audioArray = MLXArray(segment.audio)
        let result = sttModel.generate(audio: audioArray)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let speaker = resolveSpeaker(channel: channel, speakerIndex: segment.speakerIndex)

        // Compute base offset from recording start
        let baseOffset: Float
        if let start = recordingStartTime {
            baseOffset = Float(segment.startTime.timeIntervalSince(start))
        } else {
            baseOffset = 0
        }

        // Write and store per-sentence for precise batch speaker matching
        if let sentences = result.segments, !sentences.isEmpty {
            for sentence in sentences {
                guard let sentenceText = sentence["text"] as? String,
                      let sentenceStart = sentence["start"] as? Double else { continue }
                let trimmed = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let sentenceTime = segment.startTime.addingTimeInterval(sentenceStart)
                transcriptSegments.append(TranscriptSegment(
                    offsetSeconds: baseOffset + Float(sentenceStart),
                    text: trimmed,
                    channel: channel,
                    timestamp: MarkdownWriter.formatTime(sentenceTime),
                    startTime: sentenceTime
                ))
                await writer.writeSegment(time: sentenceTime, speaker: speaker, text: trimmed)
            }
        } else {
            // Fallback: write whole segment as one entry
            transcriptSegments.append(TranscriptSegment(
                offsetSeconds: baseOffset,
                text: text,
                channel: channel,
                timestamp: MarkdownWriter.formatTime(segment.startTime),
                startTime: segment.startTime
            ))
            await writer.writeSegment(time: segment.startTime, speaker: speaker, text: text)
        }
    }

    private func resolveSpeaker(channel: String, speakerIndex: Int) -> String {
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

        // Lazy-load batch Sortformer models (cached on disk, loads fast)
        if batchSortformerMic == nil {
            do {
                batchSortformerMic = try await SortformerModel.fromPretrained(
                    "mlx-community/diar_sortformer_4spk-v1-fp32"
                )
            } catch {
                Log.error("Failed to load batch diarization model: \(error)")
                return
            }
        }
        if batchSortformerSys == nil && !config.micOnly {
            do {
                batchSortformerSys = try await SortformerModel.fromPretrained(
                    "mlx-community/diar_sortformer_4spk-v1-fp32"
                )
            } catch {
                Log.error("Failed to load batch diarization model: \(error)")
                return
            }
        }

        batchPassCount += 1

        // Run batch diarization on mic channel (read from disk, temporary memory)
        var micTurns: [DiarizationSegment] = []
        if micPCM.sampleCount > 0, let model = batchSortformerMic {
            do {
                let samples = try micPCM.readAll()
                let output = try await model.generate(audio: MLXArray(samples))
                micTurns = output.segments
            } catch {
                Log.error("Batch diarization (mic) error: \(error)")
            }
        }

        // Run batch diarization on system channel (read from disk, temporary memory)
        var sysTurns: [DiarizationSegment] = []
        if sysPCM.sampleCount > 0, let model = batchSortformerSys {
            do {
                let samples = try sysPCM.readAll()
                let output = try await model.generate(audio: MLXArray(samples))
                sysTurns = output.segments
            } catch {
                Log.error("Batch diarization (system) error: \(error)")
            }
        }

        let totalTurns = micTurns.count + sysTurns.count
        await rebuildTranscript(micTurns: micTurns, sysTurns: sysTurns)

        let passLabel = isFinal ? "final" : "pass \(batchPassCount)"
        Log.info("Speaker labels updated (\(passLabel), \(totalTurns) turns)")
    }

    private func rebuildTranscript(
        micTurns: [DiarizationSegment],
        sysTurns: [DiarizationSegment]
    ) async {
        let segments = transcriptSegments.map { seg in
            let turns = seg.channel == "mic" ? micTurns : sysTurns
            let speaker = resolveBatchSpeaker(
                offsetSeconds: seg.offsetSeconds,
                channel: seg.channel,
                turns: turns
            )
            return (timestamp: seg.timestamp, speaker: speaker, text: seg.text)
        }
        await writer.rewriteAll(segments: segments)
    }

    private func resolveBatchSpeaker(
        offsetSeconds: Float,
        channel: String,
        turns: [DiarizationSegment]
    ) -> String {
        // 1. Find containing turn
        for turn in turns {
            if offsetSeconds >= turn.start && offsetSeconds <= turn.end {
                return batchSpeakerName(index: turn.speaker, channel: channel)
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
            return batchSpeakerName(index: speaker, channel: channel)
        }

        // 3. Fall back to channel default
        return channel == "mic" ? config.speakerName : config.otherName
    }

    private func batchSpeakerName(index: Int, channel: String) -> String {
        if channel == "mic" {
            if index == 0 {
                return config.speakerName
            }
            return "Local \(index + 1)"
        } else {
            if index < config.otherNames.count {
                return config.otherNames[index]
            }
            if index == 0 {
                return config.otherName
            }
            return "Remote \(index + 1)"
        }
    }

    // MARK: - Status Workers

    private func statusWorker() async {
        var nextStatus = Date().addingTimeInterval(statusInterval)
        while !isStopped {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Date() >= nextStatus {
                Log.info("Status: listening...")
                nextStatus = Date().addingTimeInterval(statusInterval)
            }
        }
    }

    private func noAudioMonitor() async {
        while !isStopped {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !noAudioWarned && lastAudioTime == nil {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed >= noAudioWarningSeconds {
                    noAudioWarned = true
                    if config.micOnly {
                        Log.warning("No audio detected. Check microphone permission.")
                    } else {
                        Log.warning("No audio detected. Check Screen Recording permission or try --mic-only.")
                    }
                }
            }
        }
    }
}
