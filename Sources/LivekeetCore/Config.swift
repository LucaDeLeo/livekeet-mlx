import Foundation
import TOMLKit

// MARK: - LivekeetConfig

public struct LivekeetConfig: Sendable {
    public var outputDirectory: String
    public var filenamePattern: String
    public var speakerName: String
    public var defaultModel: String
    public var otherNames: [String]
    public var micOnly: Bool
    public var systemOnly: Bool
    public var multilingual: Bool
    public var showStatus: Bool
    public var dumpAudio: Bool
    public var disableDiarization: Bool
    public var enableCorrection: Bool

    public init(
        outputDirectory: String = "",
        filenamePattern: String = "{datetime}.md",
        speakerName: String = "Me",
        defaultModel: String = "mlx-community/parakeet-tdt-0.6b-v2",
        otherNames: [String] = [],
        micOnly: Bool = false,
        systemOnly: Bool = false,
        multilingual: Bool = false,
        showStatus: Bool = false,
        dumpAudio: Bool = false,
        disableDiarization: Bool = false,
        enableCorrection: Bool = false
    ) {
        self.outputDirectory = outputDirectory
        self.filenamePattern = filenamePattern
        self.speakerName = speakerName
        self.defaultModel = defaultModel
        self.otherNames = otherNames
        self.micOnly = micOnly
        self.systemOnly = systemOnly
        self.multilingual = multilingual
        self.showStatus = showStatus
        self.dumpAudio = dumpAudio
        self.disableDiarization = disableDiarization
        self.enableCorrection = enableCorrection
    }

    // MARK: - Computed Properties

    /// The resolved model name, accounting for the multilingual flag.
    public var modelName: String {
        if multilingual {
            return "mlx-community/parakeet-tdt-0.6b-v3"
        }
        return defaultModel
    }

    /// The primary other speaker name (first in the list, or "Other").
    public var otherName: String {
        otherNames.first ?? "Other"
    }

    // MARK: - Paths

    public static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/livekeet")
    public static let configFile = configDir.appendingPathComponent("config.toml")

    // MARK: - Load

    public static func load() throws -> LivekeetConfig {
        var config = LivekeetConfig()

        let path = configFile.path
        guard FileManager.default.fileExists(atPath: path) else {
            return config
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let toml = try TOMLTable(string: content)

        if let output = toml["output"] as? TOMLTable {
            if let dir = output["directory"] as? String {
                config.outputDirectory = dir
            }
            if let filename = output["filename"] as? String {
                config.filenamePattern = filename
            }
        }

        if let speaker = toml["speaker"] as? TOMLTable {
            if let name = speaker["name"] as? String {
                config.speakerName = name
            }
        }

        if let defaults = toml["defaults"] as? TOMLTable {
            if let model = defaults["model"] as? String {
                config.defaultModel = model
            }
        }

        return config
    }

    // MARK: - Create Default

    public static func createDefault() throws {
        let dir = configDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let configPath = configFile
        if FileManager.default.fileExists(atPath: configPath.path) {
            print("Config already exists: \(configPath.path)")
        } else {
            try defaultConfigContent.write(to: configPath, atomically: true, encoding: .utf8)
            print("Created: \(configPath.path)")
        }

        print("""

        Settings:
          speaker.name     Your name in transcripts
          output.directory Where to save files (default: current dir)
          output.filename  Pattern: {date}, {time}, {datetime}
          defaults.model   Speech recognition model

        Models (downloaded on first use):
          parakeet-tdt-0.6b-v2  English, highest accuracy (default)
          parakeet-tdt-0.6b-v3  Multilingual, 25 languages (--multilingual)
        """)
    }

    private static let defaultConfigContent = """
    # livekeet configuration

    [output]
    # Directory for transcripts (empty = current directory)
    directory = ""
    # Filename pattern: {date}, {time}, {datetime}, or any static name
    # Examples: "{datetime}.md", "{date}-meeting.md", "transcript.md"
    filename = "{datetime}.md"

    [speaker]
    # Your name in transcripts (when using system audio for calls)
    name = "Me"

    [defaults]
    # Available models (downloaded automatically on first use):
    #   mlx-community/parakeet-tdt-0.6b-v2 - English, highest accuracy (default)
    #   mlx-community/parakeet-tdt-0.6b-v3  - Multilingual, 25 languages
    model = "mlx-community/parakeet-tdt-0.6b-v2"
    """
}
