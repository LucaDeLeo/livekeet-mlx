import Foundation
import MLX
import MLXAudioVAD

// MARK: - Detected Segment

public struct DetectedSegment: Sendable {
    public let audio: [Float]
    public let startTime: Date
    public let duration: TimeInterval
    public let speakerIndex: Int
}

// MARK: - Speech Detector

/// Uses Sortformer streaming API for combined VAD + speaker diarization.
///
/// Audio is accumulated in a buffer. Every `chunkDuration` seconds of accumulated audio,
/// a chunk is fed to Sortformer. Sortformer returns diarization segments with speaker labels.
/// When a segment ends (silence gap detected by Sortformer), the corresponding audio is
/// emitted as a `DetectedSegment` for transcription.
public actor SpeechDetector {
    private let model: SortformerModel
    private let threshold: Float
    private let minDuration: TimeInterval
    private let minEnergy: Float

    // Audio accumulation
    private var pendingAudio: [Float] = []
    private var segmentAudio: [Float] = []
    private var segmentStartTime: Date?
    private var lastSegmentEndSample: Int = 0  // track position in total audio
    private var totalSamplesProcessed: Int = 0

    // Sortformer streaming state
    private var streamingState: StreamingState?
    private let sampleRate: Int = 16000
    private let chunkSeconds: Float = 2.0  // Feed chunks of this size to Sortformer

    // Track last active segment for detecting silence gaps
    private var lastActiveEndTime: Float = 0
    private var lastActiveSpeaker: Int = 0
    private var silenceGapThreshold: Float = 1.5  // seconds
    private let maxSegmentDuration: TimeInterval = 10.0  // force emit during continuous speech

    // True when Sortformer has reported at least one speech segment since the last emit.
    // Without this, accumulated silence + tiny noise blips get emitted and fed to the STT
    // model, which then hallucinates common filler words.
    private var hadSpeechSinceEmit: Bool = false

    public init(
        model: SortformerModel,
        threshold: Float = 0.5,
        minDuration: TimeInterval = 0.5,
        minEnergy: Float = 0.02
    ) {
        self.model = model
        self.threshold = threshold
        self.minDuration = minDuration
        self.minEnergy = minEnergy
        self.streamingState = model.initStreamingState()
    }

    /// Feed an audio chunk. Returns completed segments when Sortformer detects speech boundaries.
    public func feed(_ audio: [Float], at time: Date) async throws -> [DetectedSegment] {
        guard !audio.isEmpty else { return [] }

        pendingAudio.append(contentsOf: audio)
        segmentAudio.append(contentsOf: audio)

        if segmentStartTime == nil {
            segmentStartTime = time
        }

        let chunkSamples = Int(chunkSeconds * Float(sampleRate))
        var completedSegments: [DetectedSegment] = []

        // Process complete chunks
        while pendingAudio.count >= chunkSamples {
            let chunk = Array(pendingAudio.prefix(chunkSamples))
            pendingAudio.removeFirst(chunkSamples)

            let segments = try await processChunk(chunk, referenceTime: time)
            completedSegments.append(contentsOf: segments)
        }

        return completedSegments
    }

    /// Force-flush any pending audio (e.g., on shutdown).
    public func flush() async throws -> [DetectedSegment] {
        guard !pendingAudio.isEmpty || !segmentAudio.isEmpty else { return [] }

        var results: [DetectedSegment] = []

        // Process remaining pending audio
        if !pendingAudio.isEmpty {
            let segments = try await processChunk(pendingAudio, referenceTime: Date())
            results.append(contentsOf: segments)
            pendingAudio = []
        }

        // If there's still accumulated segment audio, emit it
        if !segmentAudio.isEmpty {
            if let segment = emitCurrentSegment() {
                results.append(segment)
            }
        }

        return results
    }

    // MARK: - Private

    private func processChunk(_ chunk: [Float], referenceTime: Date) async throws -> [DetectedSegment] {
        guard let state = streamingState else { return [] }

        let chunkArray = MLXArray(chunk)
        let feedStart = Date()
        let (output, newState) = try await model.feed(
            chunk: chunkArray,
            state: state,
            sampleRate: sampleRate,
            threshold: threshold,
            minDuration: Float(minDuration),
            mergeGap: 0.0
        )
        streamingState = newState
        let feedTime = Date().timeIntervalSince(feedStart)
        if feedTime > 0.5 {
            Log.warning("Sortformer feed took \(String(format: "%.1f", feedTime))s (chunk: \(String(format: "%.1f", Float(chunk.count) / Float(sampleRate)))s audio)")
        }

        var completedSegments: [DetectedSegment] = []

        // Sortformer returns segments with timestamps relative to the stream start.
        // When there's a gap between segments > silenceGapThreshold, we treat that
        // as a speech boundary and emit the accumulated audio as a segment.
        if !output.segments.isEmpty {
            Log.debug("Diarization: \(output.segments.count) segments in chunk")
            hadSpeechSinceEmit = true
        }

        for diarSegment in output.segments {
            let gapFromLast = diarSegment.start - lastActiveEndTime

            if gapFromLast > silenceGapThreshold && !segmentAudio.isEmpty {
                // Silence gap detected — emit the accumulated segment with the previous speaker's label
                if let segment = emitCurrentSegment(speakerIndex: lastActiveSpeaker) {
                    completedSegments.append(segment)
                }
                // Start new segment
                segmentStartTime = referenceTime
            }

            lastActiveSpeaker = diarSegment.speaker
            lastActiveEndTime = diarSegment.end
        }

        // Force emit if segment exceeds max duration (continuous speech with no pauses)
        let currentDuration = Double(segmentAudio.count) / Double(sampleRate)
        if currentDuration >= maxSegmentDuration {
            let speaker = output.segments.last?.speaker ?? 0
            if let segment = emitCurrentSegment(speakerIndex: speaker) {
                completedSegments.append(segment)
            }
            segmentStartTime = referenceTime
        }

        totalSamplesProcessed += chunk.count
        return completedSegments
    }

    private func emitCurrentSegment(speakerIndex: Int = 0) -> DetectedSegment? {
        guard !segmentAudio.isEmpty, let startTime = segmentStartTime else {
            resetSegmentState()
            return nil
        }

        // If Sortformer never detected speech during this accumulation, drop the buffer.
        // Otherwise the STT model gets fed mostly-silent audio and hallucinates filler words.
        guard hadSpeechSinceEmit else {
            let seconds = Double(segmentAudio.count) / Double(sampleRate)
            Log.debug("Dropped \(String(format: "%.1f", seconds))s of audio — no speech detected by Sortformer")
            resetSegmentState()
            return nil
        }

        let duration = Double(segmentAudio.count) / Double(sampleRate)
        guard duration >= minDuration else {
            resetSegmentState()
            return nil
        }

        let rms = AudioAnalysis.rms(segmentAudio)
        guard rms >= minEnergy else {
            resetSegmentState()
            return nil
        }

        Log.debug("Segment emitted: \(String(format: "%.1f", duration))s speaker=\(speakerIndex) rms=\(String(format: "%.4f", rms))")

        let segment = DetectedSegment(
            audio: segmentAudio,
            startTime: startTime,
            duration: duration,
            speakerIndex: speakerIndex
        )

        resetSegmentState()
        return segment
    }

    private func resetSegmentState() {
        segmentAudio = []
        segmentStartTime = nil
        hadSpeechSinceEmit = false
    }
}
