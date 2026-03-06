@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Configuration

let targetSampleRate: Double = 16000
let outputFrameSize = 1024  // ~64ms at 16kHz
let ringBufferCapacity = 32768  // Power-of-2 (~2s at 16kHz)
let minBufferSamples = Int(targetSampleRate * 0.2)  // 200ms pre-buffer

// MARK: - AudioChunk

public struct AudioChunk: Sendable {
    public let mic: [Float]
    public let system: [Float]
    public let timestamp: Date

    public init(mic: [Float], system: [Float], timestamp: Date = Date()) {
        self.mic = mic
        self.system = system
        self.timestamp = timestamp
    }
}

// MARK: - CMSampleBuffer Extension

extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? withAudioBufferList { audioBufferList, _ in
            guard let desc = formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(
                      standardFormatWithSampleRate: desc.mSampleRate,
                      channels: desc.mChannelsPerFrame
                  )
            else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}

// MARK: - Lock-Free Ring Buffer

final class RingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var availableCount: Int = 0
    private var lock = os_unfair_lock()
    private var underrunCount: Int = 0
    private var overflowCount: Int = 0
    private var overflowSamples: Int = 0

    init(capacity: Int) {
        precondition(capacity & (capacity - 1) == 0, "Ring buffer capacity must be a power of 2")
        self.capacity = capacity
        self.mask = capacity - 1
        self.buffer = .allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let toWrite = min(count, capacity)
        let overflow = (availableCount + toWrite) - capacity
        if overflow > 0 {
            overflowCount += 1
            overflowSamples += overflow
            readIndex = (readIndex + overflow) & mask
            availableCount -= overflow
        }

        let firstPart = min(toWrite, capacity - writeIndex)
        buffer.advanced(by: writeIndex).update(from: samples, count: firstPart)
        if firstPart < toWrite {
            buffer.update(from: samples.advanced(by: firstPart), count: toWrite - firstPart)
        }
        writeIndex = (writeIndex + toWrite) & mask
        availableCount += toWrite
    }

    func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                write(base, count: samples.count)
            }
        }
    }

    func readFloat(into output: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let toRead = min(count, availableCount)

        let firstPart = min(toRead, capacity - readIndex)
        output.update(from: buffer.advanced(by: readIndex), count: firstPart)
        if firstPart < toRead {
            output.advanced(by: firstPart).update(from: buffer, count: toRead - firstPart)
        }

        if toRead < count {
            for i in toRead..<count {
                output[i] = 0
            }
            if toRead > 0 { underrunCount += 1 }
        }

        readIndex = (readIndex + toRead) & mask
        availableCount -= toRead
        return toRead
    }

    var available: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return availableCount
    }

    var underruns: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return underrunCount
    }

    var overflows: (count: Int, samples: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (count: overflowCount, samples: overflowSamples)
    }
}

// MARK: - Capture Error

public enum CaptureError: Error, LocalizedError {
    case noDisplay
    case microphonePermissionDenied
    case screenCapturePermissionDenied

    public var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found"
        case .microphonePermissionDenied: return "Microphone permission not granted"
        case .screenCapturePermissionDenied: return "Screen recording permission not granted"
        }
    }
}

// MARK: - Audio Capture

public final class AudioCapture: @unchecked Sendable {
    private var stream: SCStream?
    private var micEngine: AVAudioEngine?
    private var outputHandler: StreamOutputHandler?
    private let isRunning = OSAllocatedUnfairLock(initialState: false)
    private var outputTimer: DispatchSourceTimer?

    let systemBuffer = RingBuffer(capacity: ringBufferCapacity)
    let micBuffer = RingBuffer(capacity: ringBufferCapacity)
    private let outputQueue = DispatchQueue(label: "livekeet.output", qos: .userInteractive)
    private let audioSampleQueue = DispatchQueue(label: "livekeet.sck-audio", qos: .userInteractive)
    private let screenDropQueue = DispatchQueue(label: "livekeet.screen-drop", qos: .background)

    private var systemAudioConverter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private var converterLock = os_unfair_lock()

    private let systemAudioFrameCount = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var lastSystemPTS: CMTime = .invalid
    private var lastSystemDuration: CMTime = .invalid

    // Stream restart state
    private struct RestartState {
        var count = 0
        var isRestarting = false
        var lastTime: Date?
        var lastAttemptTime: Date?
    }
    private let maxRestarts = 20
    private let minRestartInterval: TimeInterval = 3
    private let restartState = OSAllocatedUnfairLock(initialState: RestartState())

    public let micOnly: Bool
    public let systemOnly: Bool
    public var micGain: Float = 1.0
    public private(set) var micPermissionDenied = false

    public init(micOnly: Bool = false, systemOnly: Bool = false) {
        self.micOnly = micOnly
        self.systemOnly = systemOnly
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: - Device Listing

    public struct AudioDevice: Sendable {
        public let name: String
        public let isDefault: Bool
    }

    public static func listDevices() -> [AudioDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [.microphone, .external]
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return devices.map { device in
            AudioDevice(
                name: device.localizedName,
                isDefault: device.uniqueID == defaultID
            )
        }
    }

    // MARK: - Permissions

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Stream Configuration

    private func makeStreamConfig() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.queueDepth = 8
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        return config
    }

    // MARK: - Start/Stop

    public func start() async throws -> AsyncStream<AudioChunk> {
        if !systemOnly {
            let hasPermission = await requestMicrophonePermission()
            if !hasPermission {
                micPermissionDenied = true
                Log.warning("Microphone permission not granted")
            }
        }

        if !micOnly {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw CaptureError.noDisplay
            }

            let config = makeStreamConfig()
            let filter = SCContentFilter(display: display, excludingWindows: [])

            outputHandler = StreamOutputHandler(capture: self)
            stream = SCStream(filter: filter, configuration: config, delegate: outputHandler)
            try stream?.addStreamOutput(outputHandler!, type: .audio, sampleHandlerQueue: audioSampleQueue)
            try stream?.addStreamOutput(outputHandler!, type: .screen, sampleHandlerQueue: screenDropQueue)
            try await stream?.startCapture()
        }

        if !systemOnly {
            try startMicrophoneCapture()
        }
        isRunning.withLock { $0 = true }

        return startOutputLoop()
    }

    public func stop() async {
        isRunning.withLock { $0 = false }
        outputTimer?.cancel()
        outputTimer = nil
        if !systemOnly {
            micEngine?.inputNode.removeTap(onBus: 0)
            micEngine?.stop()
        }
        if !micOnly {
            try? await stream?.stopCapture()
            stream = nil
        }
    }

    // MARK: - Audio Conversion

    private func convertAndExtractSamples(
        from inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        gain: Float = 1.0
    ) -> [Float]? {
        let ratio = targetSampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil,
              let floatData = outputBuffer.floatChannelData else {
            return nil
        }

        let count = Int(outputBuffer.frameLength)
        let ptr = floatData[0]

        if gain == 1.0 {
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }

        var result = [Float](repeating: 0, count: count)
        var gainValue = gain
        vDSP_vsmul(ptr, 1, &gainValue, &result, 1, vDSP_Length(count))
        return result
    }

    // MARK: - Process System Audio

    func processSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let pcmBuffer = sampleBuffer.asPCMBuffer else { return }

        let currentPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let currentDuration = CMSampleBufferGetDuration(sampleBuffer)

        os_unfair_lock_lock(&converterLock)

        if lastSystemPTS.isValid && currentPTS.isValid {
            let expectedPTS = CMTimeAdd(lastSystemPTS, lastSystemDuration)
            let gap = CMTimeSubtract(currentPTS, expectedPTS)
            let gapSeconds = CMTimeGetSeconds(gap)
            if gapSeconds > 1.0 {
                Log.warning("System audio gap (\(String(format: "%.0f", gapSeconds * 1000))ms), restarting stream")
                os_unfair_lock_unlock(&converterLock)
                restartCapture()
                return
            } else if gapSeconds > 0.2 {
                Log.warning("System audio gap (\(String(format: "%.0f", gapSeconds * 1000))ms)")
            }
        }
        lastSystemPTS = currentPTS
        lastSystemDuration = currentDuration

        if let existing = systemAudioConverter, existing.inputFormat != pcmBuffer.format {
            Log.info("System audio format changed, recreating converter")
            systemAudioConverter = nil
        }

        if systemAudioConverter == nil {
            guard let converter = AVAudioConverter(from: pcmBuffer.format, to: outputFormat) else {
                os_unfair_lock_unlock(&converterLock)
                Log.warning("Could not create system audio converter")
                return
            }
            systemAudioConverter = converter
            Log.info("System audio: \(pcmBuffer.format.sampleRate)Hz, \(pcmBuffer.format.channelCount)ch")
        }

        let converter = systemAudioConverter!
        os_unfair_lock_unlock(&converterLock)

        guard let samples = convertAndExtractSamples(from: pcmBuffer, using: converter) else {
            return
        }
        systemBuffer.write(samples)
        systemAudioFrameCount.withLock { $0 += 1 }

        restartState.withLock { state in
            if let lastRestart = state.lastTime,
               Date().timeIntervalSince(lastRestart) > 30 {
                state.count = 0
                state.lastTime = nil
            }
        }
    }

    private func clearSystemAudioConverter() {
        os_unfair_lock_lock(&converterLock)
        systemAudioConverter = nil
        lastSystemPTS = .invalid
        lastSystemDuration = .invalid
        os_unfair_lock_unlock(&converterLock)
    }

    // MARK: - Microphone Capture

    private func startMicrophoneCapture() throws {
        micEngine = AVAudioEngine()
        guard let engine = micEngine else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        Log.info("Mic: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            Log.warning("Could not create mic converter")
            return
        }

        let micGain = self.micGain
        let micBuffer = self.micBuffer

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] inputBuffer, _ in
            guard let self,
                  let samples = self.convertAndExtractSamples(from: inputBuffer, using: converter, gain: micGain)
            else { return }
            micBuffer.write(samples)
        }

        try engine.start()
        Log.info("Microphone started")
    }

    // MARK: - Output Loop → AsyncStream

    private func startOutputLoop() -> AsyncStream<AudioChunk> {
        let systemBuffer = self.systemBuffer
        let micBuffer = self.micBuffer
        let includeMic = !self.systemOnly
        let isMicOnly = self.micOnly

        let systemFloats = UnsafeMutablePointer<Float>.allocate(capacity: outputFrameSize)
        let micFloats = UnsafeMutablePointer<Float>.allocate(capacity: outputFrameSize)
        systemFloats.initialize(repeating: 0, count: outputFrameSize)
        micFloats.initialize(repeating: 0, count: outputFrameSize)

        let intervalNanos = UInt64(Double(outputFrameSize) / targetSampleRate * 1_000_000_000)

        return AsyncStream { continuation in
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.outputQueue)
            timer.schedule(
                deadline: .now(),
                repeating: .nanoseconds(Int(intervalNanos)),
                leeway: .nanoseconds(0)
            )

            var outputStarted = false
            var lastWatchdogFrameCount: UInt64 = 0
            var watchdogStaleTicks = 0
            var lastMicOverflows = 0
            var lastSysOverflows = 0
            let watchdogThresholdTicks = 16  // ~1s at 64ms intervals
            weak var weakSelf = self

            timer.setEventHandler { [systemBuffer, micBuffer, systemFloats, micFloats] in
                guard let strongSelf = weakSelf, strongSelf.isRunning.withLock({ $0 }) else { return }

                // For mic-only mode, wait for mic data; otherwise wait for system data
                if !isMicOnly {
                    let sysAvailable = systemBuffer.available
                    if !outputStarted {
                        if sysAvailable < minBufferSamples { return }
                        outputStarted = true
                        Log.info("Output started")
                    }

                    // System audio watchdog
                    let currentFrameCount = strongSelf.systemAudioFrameCount.withLock { $0 }
                    if currentFrameCount == lastWatchdogFrameCount {
                        watchdogStaleTicks += 1
                        if watchdogStaleTicks == watchdogThresholdTicks {
                            Log.warning("System audio stalled, attempting restart")
                            strongSelf.restartCapture()
                        }
                    } else {
                        lastWatchdogFrameCount = currentFrameCount
                        watchdogStaleTicks = 0
                    }

                    _ = systemBuffer.readFloat(into: systemFloats, count: outputFrameSize)
                }

                if includeMic {
                    if isMicOnly && !outputStarted {
                        if micBuffer.available < minBufferSamples { return }
                        outputStarted = true
                        Log.info("Output started (mic-only)")
                    }
                    _ = micBuffer.readFloat(into: micFloats, count: outputFrameSize)
                }

                // Check for ring buffer overflows
                let currentMicOvf = micBuffer.overflows.count
                let currentSysOvf = systemBuffer.overflows.count
                if currentMicOvf > lastMicOverflows {
                    Log.warning("Mic buffer overflow: \(currentMicOvf - lastMicOverflows) events since last check")
                    lastMicOverflows = currentMicOvf
                }
                if currentSysOvf > lastSysOverflows {
                    Log.warning("System buffer overflow: \(currentSysOvf - lastSysOverflows) events since last check")
                    lastSysOverflows = currentSysOvf
                }

                let micArray = Array(UnsafeBufferPointer(start: micFloats, count: outputFrameSize))
                let sysArray = isMicOnly
                    ? [Float]()
                    : Array(UnsafeBufferPointer(start: systemFloats, count: outputFrameSize))

                let chunk = AudioChunk(mic: micArray, system: sysArray)
                continuation.yield(chunk)
            }

            timer.setCancelHandler {
                systemFloats.deallocate()
                micFloats.deallocate()
                continuation.finish()
            }

            continuation.onTermination = { _ in
                timer.cancel()
            }

            self.outputTimer = timer
            timer.resume()
        }
    }

    // MARK: - Restart Capture

    func restartCapture() {
        Task { await performRestart() }
    }

    private func performRestart() async {
        let attempt: (num: Int, max: Int)? = restartState.withLock { state in
            guard !state.isRestarting, state.count < maxRestarts else { return nil }
            if let lastAttempt = state.lastAttemptTime,
               Date().timeIntervalSince(lastAttempt) < minRestartInterval {
                return nil
            }
            state.isRestarting = true
            state.count += 1
            state.lastAttemptTime = Date()
            return (state.count, maxRestarts)
        }

        guard let attempt else {
            if restartState.withLock({ $0.count >= maxRestarts && !$0.isRestarting }) {
                Log.error("Stream restart: max retries (\(maxRestarts)) exceeded")
            }
            return
        }
        defer { restartState.withLock { $0.isRestarting = false } }

        let backoff = min(0.25 * pow(2.0, Double(attempt.num - 1)), 10.0)
        Log.info("Stream restart: attempt \(attempt.num)/\(attempt.max) (backoff \(Int(backoff))s)")
        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))

        guard isRunning.withLock({ $0 }) else { return }

        try? await stream?.stopCapture()
        stream = nil
        clearSystemAudioConverter()

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw CaptureError.noDisplay
            }
            let config = makeStreamConfig()
            let filter = SCContentFilter(display: display, excludingWindows: [])

            outputHandler = StreamOutputHandler(capture: self)
            stream = SCStream(filter: filter, configuration: config, delegate: outputHandler)
            try stream?.addStreamOutput(outputHandler!, type: .audio, sampleHandlerQueue: audioSampleQueue)
            try stream?.addStreamOutput(outputHandler!, type: .screen, sampleHandlerQueue: screenDropQueue)
            try await stream?.startCapture()
            restartState.withLock { $0.lastTime = Date() }
            Log.info("Stream restart: success")
        } catch {
            Log.error("Stream restart: failed - \(error.localizedDescription)")
        }
    }
}

// MARK: - Stream Output Handler

final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    weak var capture: AudioCapture?

    init(capture: AudioCapture) {
        self.capture = capture
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        capture?.processSystemAudio(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        Log.error("Stream error: [\(nsError.domain) \(nsError.code)] \(nsError.localizedDescription)")
        if nsError.code == -3808 { return }
        capture?.restartCapture()
    }
}
