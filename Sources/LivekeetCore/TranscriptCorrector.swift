import Foundation

/// Calls a Python sidecar script (using claude-runner + Claude Haiku) to fix STT errors.
public actor TranscriptCorrector {

    public struct Correction: Codable, Sendable {
        public let index: Int
        public let text: String
    }

    private struct SegmentWire: Codable {
        let timestamp: String
        let speaker: String
        let text: String
    }

    private struct Input: Codable {
        let segments: [SegmentWire]
        let context: [SegmentWire]
        let speakers: [String]
    }

    private struct Output: Codable {
        let corrections: [Correction]?
        let error: String?
    }

    private let scriptURL: URL
    private let cleanEnv: [String: String]
    private var available = true
    private let timeoutSeconds: Double = 120

    public init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("livekeet_correct_\(ProcessInfo.processInfo.processIdentifier).py")
        try Self.embeddedScript.write(to: url, atomically: true, encoding: .utf8)
        self.scriptURL = url

        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CLAUDE") {
            env.removeValue(forKey: key)
        }
        self.cleanEnv = env
    }

    public func correct(
        segments: [TranscriptSegment],
        context: [TranscriptSegment],
        speakers: [String]
    ) async -> [Correction] {
        guard available else { return [] }

        let toWire: (TranscriptSegment) -> SegmentWire = {
            SegmentWire(timestamp: $0.timestamp, speaker: $0.speaker, text: $0.text)
        }
        let input = Input(
            segments: segments.map(toWire),
            context: context.map(toWire),
            speakers: speakers
        )
        guard let inputJSON = try? JSONEncoder().encode(input) else {
            Log.error("Correction: failed to encode input")
            return []
        }

        do {
            let data = try await runScript(inputJSON: inputJSON)
            let output = try JSONDecoder().decode(Output.self, from: data)

            if let error = output.error {
                Log.error("Correction API error: \(error)")
                return []
            }
            return output.corrections ?? []
        } catch CorrectorError.notAvailable(let reason) {
            Log.warning("Transcript correction disabled: \(reason)")
            available = false
            return []
        } catch {
            Log.error("Correction failed: \(error)")
            return []
        }
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    // MARK: - Process Management

    private func runScript(inputJSON: Data) async throws -> Data {
        let scriptPath = scriptURL.path
        let timeout = timeoutSeconds
        let env = cleanEnv

        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptPath]
            process.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                throw CorrectorError.notAvailable("python3 not found or failed to launch")
            }

            // Kill process if it exceeds timeout
            let workItem = DispatchWorkItem { [process] in
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: workItem)

            stdinPipe.fileHandleForWriting.write(inputJSON)
            stdinPipe.fileHandleForWriting.closeFile()

            let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            workItem.cancel()

            // Check for import errors (claude-runner not installed)
            if process.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                if stderr.contains("ModuleNotFoundError") || stderr.contains("No module named") {
                    throw CorrectorError.notAvailable(
                        "claude-runner not installed. Run: pip install -e ~/dev/claude-runner"
                    )
                }
                if !outputData.isEmpty {
                    return outputData  // Script wrote JSON error to stdout
                }
                throw CorrectorError.processFailed(stderr.prefix(500).description)
            }

            return outputData
        }.value
    }

    private enum CorrectorError: Error, CustomStringConvertible {
        case notAvailable(String)
        case processFailed(String)

        var description: String {
            switch self {
            case .notAvailable(let reason): return reason
            case .processFailed(let msg): return "Process failed: \(msg)"
            }
        }
    }

    // MARK: - Embedded Python Script

    private static let embeddedScript = """
    #!/usr/bin/env python3
    import json, sys
    from claude_runner import run_sync, clean_claude_env

    clean_claude_env()

    data = json.load(sys.stdin)
    segments = data["segments"]
    context = data.get("context", [])
    speakers = data.get("speakers", [])

    parts = [
        "Fix obvious speech-to-text errors in the transcript segments below.",
        "Only fix clear mistakes: misspellings, homophones, garbled words, missing punctuation.",
        "Do NOT rephrase, restructure, or change meaning.",
        "",
        'Return a JSON array: [{"index": 0, "text": "corrected text"}, ...]',
        "Include ONLY segments that need corrections. Return [] if all are correct.",
        "Output ONLY the JSON array, no markdown fences, no explanation.",
    ]

    if speakers:
        parts.append(f"\\nSpeakers in this conversation: {', '.join(speakers)}")

    if context:
        parts.append("\\nRecent context (for reference, do NOT correct):")
        for s in context:
            parts.append(f"  [{s['timestamp']}] {s['speaker']}: {s['text']}")

    parts.append("\\nSegments to correct:")
    for i, s in enumerate(segments):
        parts.append(f'{i}: [{s["timestamp"]}] {s["speaker"]}: "{s["text"]}"')

    result = run_sync(
        "\\n".join(parts),
        model="claude-haiku-4-5-20251001",
        system_prompt="You are a transcription correction assistant. Output only valid JSON arrays.",
    )

    if result.is_error:
        json.dump({"error": result.error}, sys.stdout)
        sys.exit(0)

    text = result.text.strip()
    if text.startswith("```"):
        lines = text.split("\\n")
        text = "\\n".join(lines[1:-1] if lines[-1].startswith("```") else lines[1:])

    try:
        corrections = json.loads(text)
        if not isinstance(corrections, list):
            corrections = []
    except json.JSONDecodeError:
        corrections = []

    json.dump({"corrections": corrections}, sys.stdout)
    """
}
