import Foundation

/// Strips Whisper/Parakeet hallucination tokens (e.g. `[BLANK_AUDIO]`, `[MUSIC]`) from STT output.
public enum TranscriptArtifactFilter {
    static let artifacts: Set<String> = [
        "[BLANK_AUDIO]",
        "[NO_SPEECH]",
        "(blank audio)",
        "(no speech)",
        "[MUSIC]",
        "[APPLAUSE]",
        "[LAUGHTER]",
        "[SILENCE]",
        "<|nospeech|>",
    ]

    public static func clean(_ text: String) -> String {
        // Every token starts with `[`, `(`, or `<` — skip the full scan when none are present.
        if !text.contains(where: { $0 == "[" || $0 == "(" || $0 == "<" }) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var cleaned = text
        for artifact in artifacts {
            cleaned = cleaned.replacingOccurrences(of: artifact, with: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
