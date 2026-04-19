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
    case completed(outputPath: String)
}

// MARK: - Debug Stats

public struct DebugStats: Sendable {
    public let timestamp: Date
    public let isRecording: Bool
    public let totalSegments: Int
    public let pendingTranscriptions: Int
    public let lastAudioTime: Date?
    public let recordingStartTime: Date?
    public let lastInferenceAudioDuration: Double?
    public let lastInferenceTime: Double?
    public let lastInferenceRatio: Double?
    public let mlxActiveMemoryMB: Int
    public let mlxCacheMemoryMB: Int
    public let micOverflowCount: Int
    public let micOverflowSamples: Int
    public let systemOverflowCount: Int
    public let systemOverflowSamples: Int

    public var pipelineState: String {
        guard isRecording else { return "Idle" }
        guard let lastAudio = lastAudioTime else { return "Waiting for audio" }
        let audioAge = Date().timeIntervalSince(lastAudio)
        if audioAge > 10 { return "Stuck?" }
        if pendingTranscriptions > 0 { return "Processing" }
        return "Recording"
    }

    public var secondsSinceLastAudio: Double? {
        guard let lastAudio = lastAudioTime else { return nil }
        return Date().timeIntervalSince(lastAudio)
    }
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
    private var micDetector: SpeechDetector?
    private var sysDetector: SpeechDetector?
    private nonisolated(unsafe) let sttModel: any STTGenerationModel
    private var lazyDiarTask: Task<Void, Never>?
    private let writer: MarkdownWriter
    private let outputPath: URL
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
    private var sortformerModel: SortformerModel?
    private var batchPassCount = 0
    private var speakerRenames: [SpeakerKey: String] = [:]

    // LLM transcript correction
    private var corrector: TranscriptCorrector?
    private var lastCorrectedCount = 0
    private let correctionInterval: TimeInterval = 45
    private let correctionContextSize = 10
    private let correctionBatchSize = 20

    // Simple energy-based segmentation (when diarization is disabled)
    private var simpleSegMicAudio: [Float] = []
    private var simpleSegMicStart: Date?
    private var simpleSegSysAudio: [Float] = []
    private var simpleSegSysStart: Date?
    private let simpleSegMaxDuration: TimeInterval = 10.0
    private let simpleSegMinDuration: TimeInterval = 0.5
    private let simpleSegSilenceThreshold: Float = 0.005
    private static let minSegmentSamples = 16000  // 1.0s at 16kHz

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

    // Last STT inference stats (for debug panel)
    private var lastInferenceAudioDuration: Double?
    private var lastInferenceTime: Double?
    private var lastInferenceRatio: Double?

    /// Stream of transcript events. Safe to access from any isolation domain.
    public nonisolated var events: AsyncStream<TranscriptEvent> { eventStream }

    public init(config: LivekeetConfig, outputArg: String? = nil) async throws {
        let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation

        self.config = config
        self.capture = AudioCapture(micOnly: config.micOnly, systemOnly: config.systemOnly)

        let modelName = config.modelName
        let shortName = modelName.split(separator: "/").last.map(String.init) ?? modelName
        let diarEnabled = !config.disableDiarization
        let loadStart = Date()

        // STT: hot-start from prewarm cache if available. If the cache is empty but a prewarm
        // is in flight for THIS model, wait for it instead of kicking off a redundant fresh load.
        var sttFromCache = await ModelPrewarmer.shared.takeSTT(name: modelName)
        if sttFromCache == nil {
            await ModelPrewarmer.shared.awaitPrewarmSTT(name: modelName)
            sttFromCache = await ModelPrewarmer.shared.takeSTT(name: modelName)
        }
        let sttModel: any STTGenerationModel
        let sttElapsed: TimeInterval
        if let sttFromCache {
            sttModel = sttFromCache
            sttElapsed = 0
            Log.info("STT \(shortName): reused from prewarm cache")
        } else {
            Log.info("Loading STT \(shortName)...")
            (sttModel, sttElapsed) = try await Self.loadSTTModel(name: modelName)
        }
        self.sttModel = sttModel

        // Diarization: hot-start from cache, else start nil and fill in asynchronously.
        // While nil, feedChannel falls back to simple energy-based segmentation — recording
        // isn't blocked on Sortformer loading.
        let sortformerFromCache = diarEnabled
            ? await ModelPrewarmer.shared.takeSortformer()
            : nil
        self.sortformerModel = sortformerFromCache
        if let sortformerFromCache {
            self.micDetector = config.systemOnly ? nil : SpeechDetector(model: sortformerFromCache)
            self.sysDetector = config.micOnly ? nil : SpeechDetector(model: sortformerFromCache)
        } else {
            self.micDetector = nil
            self.sysDetector = nil
        }

        let wall = Date().timeIntervalSince(loadStart)
        let diarStatus: String = {
            if !diarEnabled { return "disabled" }
            if sortformerFromCache != nil { return "cached" }
            return "loading in background"
        }()
        Log.info(String(format: "Ready in %.1fs (STT %.1fs, diarization %@)", wall, sttElapsed, diarStatus))

        // Resolve output path
        let outputPath = resolveOutputPath(arg: outputArg, config: config)
        let (uniquePath, wasSuffixed) = ensureUniquePath(outputPath)
        if wasSuffixed {
            Log.info("Output exists; saving to \(uniquePath.lastPathComponent)")
        }
        self.outputPath = uniquePath
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
            bufferingPolicy: .unbounded
        )
        self.transcriptionStream = tStream
        self.transcriptionContinuation = tContinuation

        // Cap MLX buffer cache to prevent unbounded growth across inference calls.
        // Model weights are "active" memory, unaffected by cache limit.
        Memory.cacheLimit = 512 * 1024 * 1024  // 512 MB

        Log.info("Output: \(uniquePath.path)")

        if diarEnabled && sortformerFromCache == nil {
            self.lazyDiarTask = Task.detached(priority: .utility) { [weak self] in
                // If prewarm is still loading Sortformer, wait for its result before loading fresh.
                await ModelPrewarmer.shared.awaitPrewarmDiar()
                if let cached = await ModelPrewarmer.shared.takeSortformer() {
                    await self?.attachLazyDiarization(model: cached, elapsed: 0)
                    return
                }
                do {
                    let (model, elapsed) = try await Transcriber.loadDiarizationModel(enabled: true)
                    if let model {
                        await self?.attachLazyDiarization(model: model, elapsed: elapsed)
                    }
                } catch {
                    Log.warning("Lazy diarization load failed: \(error). Continuing with simple segmentation.")
                }
            }
        }
    }

    private func attachLazyDiarization(model: SortformerModel, elapsed: TimeInterval) {
        guard !isStopped, sortformerModel == nil else { return }
        sortformerModel = model
        micDetector = config.systemOnly ? nil : SpeechDetector(model: model)
        sysDetector = config.micOnly ? nil : SpeechDetector(model: model)
        Log.info(String(format: "Diarization attached after %.1fs", elapsed))
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

            if !config.disableDiarization {
                group.addTask {
                    await self.batchDiarizationWorker()
                }
            }

            group.addTask {
                await self.transcriptionWorker()
            }

            if config.enableCorrection {
                group.addTask {
                    await self.correctionWorker()
                }
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
        if !config.disableDiarization {
            Log.info("Running final speaker analysis...")
            await runBatchDiarization(final: true)
        }

        await writer.writeFooter()
        await capture.stop()

        // Clean up disk-backed PCM files
        micPCM.cleanup()
        sysPCM.cleanup()
        try? FileManager.default.removeItem(at: pcmTempDir)

        eventContinuation.yield(.completed(outputPath: outputPath.path))
        eventContinuation.finish()
        print("\nSaved transcript")
    }

    /// Stop the transcriber gracefully.
    public func stop() {
        isStopped = true
        lazyDiarTask?.cancel()
        lazyDiarTask = nil
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

        // Process mic and system channels
        let hasMic = !config.systemOnly
        let hasSys = !config.micOnly && !chunk.system.isEmpty

        if hasMic && hasSys, let micDet = micDetector, let sysDet = sysDetector {
            // Run both Sortformer feeds concurrently
            async let micResult: [DetectedSegment] = {
                do { return try await micDet.feed(chunk.mic, at: chunk.timestamp) }
                catch { Log.error("Mic detection error: \(error)"); return [] }
            }()
            async let sysResult: [DetectedSegment] = {
                do { return try await sysDet.feed(chunk.system, at: chunk.timestamp) }
                catch { Log.error("System detection error: \(error)"); return [] }
            }()
            let (micSegments, sysSegments) = await (micResult, sysResult)
            for segment in micSegments { enqueueTranscription(segment: segment, channel: "mic") }
            for segment in sysSegments { enqueueTranscription(segment: segment, channel: "system") }
        } else {
            if hasMic {
                await feedChannel(chunk.mic, detector: micDetector, channel: "mic", at: chunk.timestamp)
            }
            if hasSys {
                await feedChannel(chunk.system, detector: sysDetector, channel: "system", at: chunk.timestamp)
            }
        }
    }

    private func feedChannel(_ audio: [Float], detector: SpeechDetector?, channel: String, at time: Date) async {
        if let detector {
            do {
                for segment in try await detector.feed(audio, at: time) {
                    enqueueTranscription(segment: segment, channel: channel)
                }
            } catch {
                Log.error("\(channel.capitalized) detection error: \(error)")
            }
        } else {
            // Detector missing — either diarization disabled or still loading in background.
            processSimpleSegmentation(audio, channel: channel, at: time)
        }
    }

    private func enqueueTranscription(segment: DetectedSegment, channel: String) {
        segmentCounter += 1
        let item = TranscriptionWorkItem(
            segment: segment, channel: channel, segmentNumber: segmentCounter
        )
        transcriptionContinuation.yield(item)
        pendingTranscriptionCount += 1
    }

    private func processSimpleSegmentation(_ audio: [Float], channel: String, at time: Date) {
        let isSystem = channel == "system"
        if isSystem {
            simpleSegSysAudio.append(contentsOf: audio)
            if simpleSegSysStart == nil { simpleSegSysStart = time }
        } else {
            simpleSegMicAudio.append(contentsOf: audio)
            if simpleSegMicStart == nil { simpleSegMicStart = time }
        }

        let segAudio = isSystem ? simpleSegSysAudio : simpleSegMicAudio
        let segStart = isSystem ? simpleSegSysStart : simpleSegMicStart
        let duration = Double(segAudio.count) / 16000.0

        var shouldEmit = false
        if duration >= simpleSegMaxDuration {
            shouldEmit = true
        } else if duration >= simpleSegMinDuration {
            // Check if the last 0.5s is silence
            let tailCount = min(Int(16000 * 0.5), segAudio.count)
            let tail = segAudio.suffix(tailCount)
            let rms = AudioAnalysis.rms(tail)
            shouldEmit = rms < simpleSegSilenceThreshold
        }

        if shouldEmit, let start = segStart {
            let segment = DetectedSegment(
                audio: segAudio, startTime: start, duration: duration, speakerIndex: 0
            )
            enqueueTranscription(segment: segment, channel: channel)
            if isSystem {
                simpleSegSysAudio = []
                simpleSegSysStart = nil
            } else {
                simpleSegMicAudio = []
                simpleSegMicStart = nil
            }
        }
    }

    private func flushSimpleSegments() {
        if !simpleSegMicAudio.isEmpty, let start = simpleSegMicStart {
            let duration = Double(simpleSegMicAudio.count) / 16000.0
            let segment = DetectedSegment(
                audio: simpleSegMicAudio, startTime: start, duration: duration, speakerIndex: 0
            )
            enqueueTranscription(segment: segment, channel: "mic")
            simpleSegMicAudio = []
            simpleSegMicStart = nil
        }
        if !simpleSegSysAudio.isEmpty, let start = simpleSegSysStart {
            let duration = Double(simpleSegSysAudio.count) / 16000.0
            let segment = DetectedSegment(
                audio: simpleSegSysAudio, startTime: start, duration: duration, speakerIndex: 0
            )
            enqueueTranscription(segment: segment, channel: "system")
            simpleSegSysAudio = []
            simpleSegSysStart = nil
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
        flushSimpleSegments()
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
            guard item.segment.audio.count >= Self.minSegmentSamples else { continue }

            // Trim leading/trailing silence to improve STT accuracy
            let audio = Self.trimSilence(item.segment.audio, threshold: simpleSegSilenceThreshold, windowSize: 320)
            guard audio.count >= Self.minSegmentSamples else { continue }
            let audioDuration = Double(audio.count) / 16000.0
            nonisolated(unsafe) let model = sttModel
            let inferenceStart = Date()

            let result = await Task.detached {
                let audioArray = MLXArray(audio)
                let output = model.generate(audio: audioArray)
                return output
            }.value

            let inferenceTime = Date().timeIntervalSince(inferenceStart)
            let ratio = audioDuration / inferenceTime
            Log.info("STT inference: \(String(format: "%.1f", audioDuration))s audio in \(String(format: "%.1f", inferenceTime))s (\(String(format: "%.1f", ratio))x realtime)")
            lastInferenceAudioDuration = audioDuration
            lastInferenceTime = inferenceTime
            lastInferenceRatio = ratio

            await writeTranscriptionResult(result, segment: item.segment, channel: item.channel)
        }
    }

    private func writeTranscriptionResult(
        _ result: STTOutput, segment: DetectedSegment, channel: String
    ) async {
        let text = TranscriptArtifactFilter.clean(result.text)
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
                let trimmed = TranscriptArtifactFilter.clean(sentenceText)
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
        await periodicWorker(initialDelay: 30, interval: 30) {
            await self.runBatchDiarization(final: false)
        }
    }

    private func runBatchDiarization(final isFinal: Bool) async {
        guard let sortformerModel, !transcriptSegments.isEmpty else { return }

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
        await rewriteAndNotify()
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

    // MARK: - LLM Transcript Correction

    private func correctionWorker() async {
        do {
            let settings = TranscriptCorrector.Settings(
                basePrompt: config.correctionPrompt,
                model: config.correctionModel
            )
            corrector = try TranscriptCorrector(settings: settings)
        } catch {
            Log.error("Failed to initialize transcript corrector: \(error)")
            return
        }

        await periodicWorker(initialDelay: 60, interval: Int(correctionInterval)) {
            await self.runCorrectionPass()
        }

        // Final pass on remaining segments
        await runCorrectionPass()
        await corrector?.cleanup()
    }

    private func periodicWorker(initialDelay: Int, interval: Int, work: () async -> Void) async {
        for _ in 0..<initialDelay {
            if isStopped { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        while !isStopped {
            await work()
            for _ in 0..<interval {
                if isStopped { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func runCorrectionPass() async {
        guard let corrector, !transcriptSegments.isEmpty else { return }

        let total = transcriptSegments.count
        guard total > lastCorrectedCount else { return }

        // Context: recent already-corrected segments
        let contextStart = max(0, lastCorrectedCount - correctionContextSize)
        let contextSegments = (contextStart < lastCorrectedCount)
            ? Array(transcriptSegments[contextStart..<lastCorrectedCount])
            : []

        // New segments to correct
        let endIndex = min(total, lastCorrectedCount + correctionBatchSize)
        let targetSegments = Array(transcriptSegments[lastCorrectedCount..<endIndex])

        var speakers = Set<String>()
        speakers.insert(config.speakerName)
        for name in config.otherNames { speakers.insert(name) }

        let corrections = await corrector.correct(
            segments: targetSegments, context: contextSegments, speakers: Array(speakers)
        )

        if !corrections.isEmpty {
            var correctedCount = 0
            for correction in corrections {
                let actualIndex = lastCorrectedCount + correction.index
                guard actualIndex < transcriptSegments.count else { continue }
                let seg = transcriptSegments[actualIndex]
                guard correction.text != seg.text else { continue }

                transcriptSegments[actualIndex] = TranscriptSegment(
                    offsetSeconds: seg.offsetSeconds,
                    text: correction.text,
                    channel: seg.channel,
                    timestamp: seg.timestamp,
                    startTime: seg.startTime,
                    speakerIndex: seg.speakerIndex,
                    speaker: seg.speaker
                )
                correctedCount += 1
            }

            if correctedCount > 0 {
                Log.info("AI corrected \(correctedCount) segment(s)")
                await rewriteAndNotify()
            }
        }

        lastCorrectedCount = endIndex
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
        await rewriteAndNotify()
    }

    private func rewriteAndNotify() async {
        let writerSegments = transcriptSegments.map {
            (timestamp: $0.timestamp, speaker: $0.speaker, text: $0.text)
        }
        await writer.rewriteAll(segments: writerSegments)
        eventContinuation.yield(.rewrite(transcriptSegments))
    }

    // MARK: - Debug Stats

    public func debugStats() -> DebugStats {
        let snap = Memory.snapshot()
        let micOvf = capture.micBuffer.overflows
        let sysOvf = capture.systemBuffer.overflows
        return DebugStats(
            timestamp: Date(),
            isRecording: !isStopped,
            totalSegments: transcriptSegments.count,
            pendingTranscriptions: pendingTranscriptionCount,
            lastAudioTime: lastAudioTime,
            recordingStartTime: recordingStartTime,
            lastInferenceAudioDuration: lastInferenceAudioDuration,
            lastInferenceTime: lastInferenceTime,
            lastInferenceRatio: lastInferenceRatio,
            mlxActiveMemoryMB: snap.activeMemory / (1024 * 1024),
            mlxCacheMemoryMB: snap.cacheMemory / (1024 * 1024),
            micOverflowCount: micOvf.count,
            micOverflowSamples: micOvf.samples,
            systemOverflowCount: sysOvf.count,
            systemOverflowSamples: sysOvf.samples
        )
    }

    // MARK: - Model Loading

    static func loadSTTModel(name: String) async throws -> (any STTGenerationModel, TimeInterval) {
        let start = Date()
        let lowered = name.lowercased()
        let model: any STTGenerationModel
        if lowered.contains("qwen") && lowered.contains("asr") {
            model = try await Qwen3ASRModel.fromPretrained(name)
        } else if lowered.contains("voxtral") {
            model = try await VoxtralRealtimeModel.fromPretrained(name)
        } else {
            model = try await ParakeetModel.fromPretrained(name)
        }
        return (model, Date().timeIntervalSince(start))
    }

    static func loadDiarizationModel(enabled: Bool) async throws -> (SortformerModel?, TimeInterval) {
        guard enabled else { return (nil, 0) }
        let start = Date()
        let model = try await SortformerModel.fromPretrained(diarizationModelName)
        return (model, Date().timeIntervalSince(start))
    }

    static let diarizationModelName = "mlx-community/diar_sortformer_4spk-v1-fp32"

    // MARK: - Audio Utilities

    /// Trim leading and trailing silence from audio samples using a sliding RMS window.
    static func trimSilence(_ audio: [Float], threshold: Float, windowSize: Int) -> [Float] {
        guard audio.count > windowSize else { return audio }

        let thresholdSquared = threshold * threshold * Float(windowSize)

        // Compute initial window sum-of-squares
        var sum: Float = 0
        for j in 0..<windowSize { sum += audio[j] * audio[j] }

        // Slide forward to find first window above threshold
        var start = 0
        if sum >= thresholdSquared {
            start = 0
        } else {
            var found = false
            for i in 1...(audio.count - windowSize) {
                sum -= audio[i - 1] * audio[i - 1]
                sum += audio[i + windowSize - 1] * audio[i + windowSize - 1]
                if sum >= thresholdSquared {
                    start = i
                    found = true
                    break
                }
            }
            if !found { return audio }
        }

        // Compute initial window sum-of-squares from end
        var sumEnd: Float = 0
        let lastStart = audio.count - windowSize
        for j in lastStart..<audio.count { sumEnd += audio[j] * audio[j] }

        // Slide backward to find last window above threshold
        var end = audio.count
        if sumEnd >= thresholdSquared {
            end = audio.count
        } else {
            for i in stride(from: lastStart - 1, through: start, by: -1) {
                sumEnd -= audio[i + windowSize] * audio[i + windowSize]
                sumEnd += audio[i] * audio[i]
                if sumEnd >= thresholdSquared {
                    end = min(i + windowSize, audio.count)
                    break
                }
            }
        }

        // Pad by one window on each side so quiet word-initial/-final consonants
        // (p, t, k, f, s) aren't clipped off, which makes the STT model hallucinate.
        let paddedStart = max(0, start - windowSize)
        let paddedEnd = min(audio.count, end + windowSize)

        guard paddedStart < paddedEnd, (paddedEnd - paddedStart) >= minSegmentSamples else { return audio }
        return Array(audio[paddedStart..<paddedEnd])
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
