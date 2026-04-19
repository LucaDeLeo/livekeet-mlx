import Foundation

/// Calls a Python sidecar script (using claude-runner) to fix STT errors.
///
/// Prompt assembly happens in Swift via `CorrectionPromptBuilder`; the Python script is a
/// thin wrapper that just invokes `claude_runner.run_sync` with the given prompt and model.
public actor TranscriptCorrector {

    public struct Settings: Sendable {
        public let basePrompt: String
        public let model: String

        public init(
            basePrompt: String = CorrectionPromptBuilder.defaultBasePrompt,
            model: String = CorrectionPromptBuilder.defaultModel
        ) {
            self.basePrompt = basePrompt
            self.model = model
        }
    }

    public struct Correction: Codable, Sendable {
        public let index: Int
        public let text: String
    }

    private struct Input: Codable {
        let prompt: String
        let systemPrompt: String
        let model: String

        enum CodingKeys: String, CodingKey {
            case prompt
            case systemPrompt = "system_prompt"
            case model
        }
    }

    private struct Output: Codable {
        let corrections: [Correction]?
        let error: String?
    }

    private let scriptURL: URL
    private let cleanEnv: [String: String]
    private let settings: Settings
    private let promptBuilder: CorrectionPromptBuilder
    private var available = true
    private let timeoutSeconds: Double = 120

    public init(settings: Settings = Settings()) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("livekeet_correct_\(ProcessInfo.processInfo.processIdentifier).py")
        try Self.embeddedScript.write(to: url, atomically: true, encoding: .utf8)
        self.scriptURL = url

        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CLAUDE") {
            env.removeValue(forKey: key)
        }
        self.cleanEnv = env

        self.settings = settings
        self.promptBuilder = CorrectionPromptBuilder(basePrompt: settings.basePrompt)
    }

    public func correct(
        segments: [TranscriptSegment],
        context: [TranscriptSegment],
        speakers: [String]
    ) async -> [Correction] {
        guard available else { return [] }

        let prompt = promptBuilder.build(
            segments: segments, context: context, speakers: speakers
        )
        let input = Input(
            prompt: prompt,
            systemPrompt: CorrectionPromptBuilder.defaultSystemPrompt,
            model: settings.model
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
            let corrections = output.corrections ?? []
            logDiffs(corrections: corrections, originals: segments)
            return corrections
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

    // MARK: - Diff Logging

    private func logDiffs(corrections: [Correction], originals: [TranscriptSegment]) {
        for correction in corrections {
            guard correction.index >= 0, correction.index < originals.count else { continue }
            let original = originals[correction.index].text
            guard original != correction.text else { continue }
            Log.debug("correction: '\(original)' -> '\(correction.text)'")
        }
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

    public enum CorrectorError: Error, LocalizedError, CustomStringConvertible {
        case notAvailable(String)
        case processFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notAvailable(let reason):
                return "Transcript correction unavailable: \(reason)"
            case .processFailed(let msg):
                return "Transcript correction failed: \(msg)"
            }
        }

        public var description: String { errorDescription ?? "Correction error" }
    }

    // MARK: - Embedded Python Script

    private static let embeddedScript = """
    #!/usr/bin/env python3
    import json, sys
    from claude_runner import run_sync, clean_claude_env

    clean_claude_env()

    data = json.load(sys.stdin)
    prompt = data["prompt"]
    system_prompt = data.get("system_prompt", "")
    model = data.get("model", "claude-haiku-4-5-20251001")

    result = run_sync(prompt, model=model, system_prompt=system_prompt)

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
