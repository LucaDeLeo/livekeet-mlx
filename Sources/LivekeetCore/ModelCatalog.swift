import Foundation

/// Curated list of speech-to-text models livekeet knows how to load.
/// Used by the Settings UI to render a picker; the underlying model string is still free-form
/// (stored in `LivekeetConfig.defaultModel`), so users can type any Hugging Face model id.
public struct SpeechModelDescriptor: Sendable, Identifiable, Hashable {
    public enum Backend: String, Sendable, Hashable {
        case parakeet
        case qwen3ASR
        case voxtralRealtime
    }

    public let id: String            // Hugging Face model id, used as the persisted value
    public let displayName: String   // Picker label
    public let subtitle: String      // Short descriptor shown below the picker
    public let sizeDescription: String
    public let backend: Backend

    public init(id: String, displayName: String, subtitle: String, sizeDescription: String, backend: Backend) {
        self.id = id
        self.displayName = displayName
        self.subtitle = subtitle
        self.sizeDescription = sizeDescription
        self.backend = backend
    }
}

public enum ModelCatalog {
    public static let parakeetV2 = SpeechModelDescriptor(
        id: "mlx-community/parakeet-tdt-0.6b-v2",
        displayName: "Parakeet TDT 0.6B v2",
        subtitle: "English, highest accuracy",
        sizeDescription: "~600 MB",
        backend: .parakeet
    )

    public static let parakeetV3 = SpeechModelDescriptor(
        id: "mlx-community/parakeet-tdt-0.6b-v3",
        displayName: "Parakeet TDT 0.6B v3",
        subtitle: "Multilingual (25 languages)",
        sizeDescription: "~600 MB",
        backend: .parakeet
    )

    public static let qwen3ASR = SpeechModelDescriptor(
        id: "mlx-community/Qwen3-ASR-Flash-MLX-4bit",
        displayName: "Qwen3-ASR (4-bit)",
        subtitle: "Multilingual, strong on noisy audio",
        sizeDescription: "~2 GB",
        backend: .qwen3ASR
    )

    public static let voxtral = SpeechModelDescriptor(
        id: "mlx-community/Voxtral-Mini-3B-2507-4bit",
        displayName: "Voxtral Mini 3B",
        subtitle: "Multilingual, streaming-friendly",
        sizeDescription: "~2 GB",
        backend: .voxtralRealtime
    )

    public static let availableModels: [SpeechModelDescriptor] = [
        parakeetV2, parakeetV3, qwen3ASR, voxtral,
    ]

    /// Returns the catalog descriptor whose `id` exactly matches, or `nil` for custom strings.
    public static func descriptor(for modelId: String) -> SpeechModelDescriptor? {
        availableModels.first { $0.id == modelId }
    }
}
