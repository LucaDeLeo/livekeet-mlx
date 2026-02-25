import ArgumentParser
import Foundation
import LivekeetCore

@main
struct Livekeet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "livekeet",
        abstract: "Real-time audio transcription for macOS",
        subcommands: [Record.self, Init.self, Devices.self],
        defaultSubcommand: Record.self
    )
}

// MARK: - Record Subcommand (default)

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Start recording and transcribing audio (default)"
    )

    @Argument(help: "Output file or directory (default: from config)")
    var output: String?

    @Option(name: [.short, .customLong("with")], help: "Other speaker name(s), comma-separated")
    var with: String?

    @Flag(name: [.short, .customLong("mic-only")], help: "Only capture microphone (no system audio)")
    var micOnly = false

    @Flag(help: "Use multilingual model (parakeet-tdt-0.6b-v3)")
    var multilingual = false

    @Option(help: "Model to use")
    var model: String?

    @Flag(help: "Show periodic status updates")
    var status = false

    @Flag(name: .customLong("dump-audio"), help: "Save each audio segment as a WAV file for debugging")
    var dumpAudio = false

    func run() async throws {
        var config: LivekeetConfig
        do {
            config = try LivekeetConfig.load()
        } catch {
            config = LivekeetConfig()
        }

        config.micOnly = micOnly
        config.multilingual = multilingual
        config.showStatus = status
        config.dumpAudio = dumpAudio

        if let model = model {
            config.defaultModel = model
        }

        if let with = with {
            config.otherNames = with.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        if multilingual && model != nil {
            Log.warning("--multilingual overrides --model")
        }
        if micOnly && with != nil {
            Log.warning("--with is ignored in --mic-only mode (system audio disabled)")
        }

        let transcriber = try await Transcriber(config: config, outputArg: output)

        // Install signal handlers for graceful shutdown
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            print("\nStopping...")
            Task { await transcriber.stop() }
        }
        signalSource.resume()

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        termSource.setEventHandler {
            Task { await transcriber.stop() }
        }
        termSource.resume()

        try await transcriber.run()
    }
}

// MARK: - Init Subcommand

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create default configuration file"
    )

    func run() throws {
        try LivekeetConfig.createDefault()
    }
}

// MARK: - Devices Subcommand

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available audio devices"
    )

    func run() {
        let devices = AudioCapture.listDevices()
        print("Available microphones:\n")
        for device in devices {
            let suffix = device.isDefault ? " (default)" : ""
            print("  \(device.name)\(suffix)")
        }
    }
}
