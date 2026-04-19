# Privacy Audit

Livekeet aims to run 100% locally by default. The one exception is the optional Claude Haiku transcript-correction feature, which is **opt-in** and calls the Anthropic API via a Python sidecar (`claude-runner`). This document is both the audit prompt and the record of the most recent verification.

## How to verify

Paste the following prompt into Claude Code (or any AI assistant with codebase access) from the repo root:

> Review the livekeet-mlx codebase and confirm which features make network calls and which run locally. Specifically verify:
>
> 1. **Speech-to-text** — MLX inference (Parakeet / Qwen3-ASR / Voxtral) runs entirely on-device. No audio is sent to any server.
> 2. **Audio capture** — mic via AVAudioEngine, system audio via ScreenCaptureKit. No audio is streamed or uploaded.
> 3. **Diarization** — Sortformer runs entirely on-device.
> 4. **File output** — transcripts are written as local markdown and optional raw audio dumps. No cloud sync.
> 5. **Transcript correction (opt-in)** — when `enableCorrection` is true, segments are sent to Claude Haiku via the `claude-runner` Python sidecar. Confirm this is the only code path that leaves the device with user content, and that it is disabled by default.
> 6. **Model downloads** — STT models are fetched from Hugging Face on first use (mlx-audio-swift handles this). No user data is sent.
> 7. **Update check** — Sparkle fetches `appcast.xml` once per day. No user data is sent.
> 8. **No analytics or telemetry** — confirm there are no tracking SDKs (Firebase, Sentry, Mixpanel, Amplitude, PostHog, Datadog, Segment) anywhere in the codebase.
>
> For each item, check the relevant source files and confirm (or identify) every `URLSession`, `URLRequest`, HTTP URL, and external process invocation. Output your findings as a checklist with pass/fail and a brief justification.

---

## Most recent audit

**Date:** 2026-04-19
**Auditor:** Claude Code (Opus 4.7)
**Commit:** `06318b8`

### Core features (run locally)

| # | Feature | Files checked | Result |
|---|---------|--------------|--------|
| 1 | Speech-to-text | `Sources/LivekeetCore/Transcriber.swift` | Pass — MLX STT via `mlx-audio-swift`. No network calls in the inference path. |
| 2 | Audio capture | `Sources/LivekeetCore/AudioCapture.swift` | Pass — AVAudioEngine (mic) and ScreenCaptureKit (system audio). |
| 3 | Diarization | `Sources/LivekeetCore/SpeechDetector.swift`, `Sources/LivekeetCore/Transcriber.swift` batch pass | Pass — Sortformer inference on-device. |
| 4 | File output | `Sources/LivekeetCore/MarkdownWriter.swift`, disk-backed PCM in `Transcriber.swift` | Pass — local filesystem only. No iCloud/CloudKit. |
| 5 | No analytics or telemetry | Entire `Sources/` tree | Pass — no Firebase/Sentry/Mixpanel/Amplitude/PostHog/Datadog/Segment imports. |

### Network-connected features

| Feature | Default state | Endpoint | Data sent |
|---------|---------------|----------|-----------|
| **Transcript correction (Claude Haiku)** | **Opt-in** via `AppSettings.enableCorrection` (default: `false`) | Anthropic API, via `claude-runner` Python sidecar (`Sources/LivekeetCore/TranscriptCorrector.swift`) | Recent transcript segments + optional context window. Model hardcoded to `claude-haiku-4-5-20251001`. |
| Model downloads | Automatic on first use of a new model | Hugging Face (mlx-community) | No user content — only the model name being requested. |
| Sparkle update check | Automatic, ~1×/day | `https://lucadeleo.github.io/livekeet-mlx/appcast.xml` (`Sources/LivekeetApp/Info.plist:14`) | No user content — only a conditional GET. |

### Verdict

**Default installation runs locally for transcription, diarization, and file output.** The only feature that transmits user content is the Claude Haiku correction path, and it is disabled by default. If `enableCorrection` is on, transcript segments are sent to the Anthropic API through the `claude-runner` sidecar.

Users who need a fully-offline workflow should leave `enableCorrection` off.
