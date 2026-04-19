import Foundation

/// Assembles the correction prompt sent to the Claude API (via the `claude-runner` Python sidecar).
/// Keep pure: no I/O, no state. Consumers supply the base prompt (user-editable) and structured inputs.
public struct CorrectionPromptBuilder: Sendable {
    public static let defaultBasePrompt: String = """
    Fix obvious speech-to-text errors in the transcript segments below.
    Only fix clear mistakes: misspellings, homophones, garbled words, missing punctuation.
    Do NOT rephrase, restructure, or change meaning.

    Return a JSON array: [{"index": 0, "text": "corrected text"}, ...]
    Include ONLY segments that need corrections. Return [] if all are correct.
    Output ONLY the JSON array, no markdown fences, no explanation.
    """

    public static let defaultSystemPrompt: String =
        "You are a transcription correction assistant. Output only valid JSON arrays."

    public static let defaultModel: String = "claude-haiku-4-5-20251001"

    public let basePrompt: String

    public init(basePrompt: String = CorrectionPromptBuilder.defaultBasePrompt) {
        self.basePrompt = basePrompt
    }

    public func build(
        segments: [TranscriptSegment],
        context: [TranscriptSegment],
        speakers: [String]
    ) -> String {
        var parts: [String] = [basePrompt]

        if !speakers.isEmpty {
            parts.append("")
            parts.append("Speakers in this conversation: \(speakers.joined(separator: ", "))")
        }

        if !context.isEmpty {
            parts.append("")
            parts.append("Recent context (for reference, do NOT correct):")
            for s in context {
                parts.append("  [\(s.timestamp)] \(s.speaker): \(s.text)")
            }
        }

        parts.append("")
        parts.append("Segments to correct:")
        for (i, s) in segments.enumerated() {
            parts.append("\(i): [\(s.timestamp)] \(s.speaker): \"\(s.text)\"")
        }

        return parts.joined(separator: "\n")
    }
}
