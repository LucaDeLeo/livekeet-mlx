import Foundation
import MLXAudioSTT
import MLXAudioVAD

/// Loads STT and diarization models in the background at app launch so that the first
/// "Start Recording" click is instant (or close to it). Transcriber checks this cache
/// before falling back to a fresh `fromPretrained` call.
public actor ModelPrewarmer {
    public static let shared = ModelPrewarmer()

    private nonisolated(unsafe) var cachedSTT: (name: String, model: any STTGenerationModel)?
    private var cachedSortformer: SortformerModel?
    private var prewarmTask: Task<Void, Never>?
    private var inFlightSTTName: String?
    private var inFlightDiar: Bool = false

    private init() {}

    public func startPrewarm(sttModelName: String, diarization: Bool) {
        guard prewarmTask == nil else { return }
        inFlightSTTName = sttModelName
        inFlightDiar = diarization
        prewarmTask = Task.detached(priority: .utility) { [weak self] in
            async let stt = Self.tryLoadSTT(name: sttModelName)
            async let diar = Self.tryLoadDiarization(enabled: diarization)
            let sttResult = await stt
            let diarResult = await diar
            await self?.commit(
                sttName: sttModelName,
                sttResult: sttResult,
                diarResult: diarResult
            )
        }
    }

    private static func tryLoadSTT(name: String) async -> (any STTGenerationModel, TimeInterval)? {
        do { return try await Transcriber.loadSTTModel(name: name) }
        catch {
            Log.warning("Prewarm STT failed: \(error)")
            return nil
        }
    }

    private static func tryLoadDiarization(enabled: Bool) async -> (SortformerModel, TimeInterval)? {
        guard enabled else { return nil }
        do {
            let (maybeModel, elapsed) = try await Transcriber.loadDiarizationModel(enabled: true)
            guard let model = maybeModel else { return nil }
            return (model, elapsed)
        } catch {
            Log.warning("Prewarm diarization failed: \(error)")
            return nil
        }
    }

    private func commit(
        sttName: String,
        sttResult: (any STTGenerationModel, TimeInterval)?,
        diarResult: (SortformerModel, TimeInterval)?
    ) {
        if let sttResult { cachedSTT = (sttName, sttResult.0) }
        cachedSortformer = diarResult?.0
        inFlightSTTName = nil
        inFlightDiar = false
        Log.info(String(
            format: "Prewarm complete: STT %@, diarization %@",
            sttResult.map { String(format: "%.1fs", $0.1) } ?? "skipped/failed",
            diarResult.map { String(format: "%.1fs", $0.1) } ?? "skipped/failed"
        ))
    }

    public func takeSTT(name: String) -> (any STTGenerationModel)? {
        guard let cached = cachedSTT, cached.name == name else { return nil }
        cachedSTT = nil
        return cached.model
    }

    public func takeSortformer() -> SortformerModel? {
        let m = cachedSortformer
        cachedSortformer = nil
        return m
    }

    /// Await the in-flight prewarm only if it targets this STT model. Prevents double-loads
    /// when the user clicks Start mid-prewarm, without making unrelated callers wait.
    public func awaitPrewarmSTT(name: String) async {
        guard let task = prewarmTask, inFlightSTTName == name else { return }
        _ = await task.value
    }

    public func awaitPrewarmDiar() async {
        guard let task = prewarmTask, inFlightDiar else { return }
        _ = await task.value
    }
}
