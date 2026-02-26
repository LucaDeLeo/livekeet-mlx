import Foundation
import LivekeetCore
import Observation

@Observable
final class AppSettings {
    private static let defaults = UserDefaults.standard

    var speakerName: String {
        get {
            access(keyPath: \.speakerName)
            return Self.defaults.string(forKey: "speakerName") ?? "Me"
        }
        set {
            withMutation(keyPath: \.speakerName) {
                Self.defaults.set(newValue, forKey: "speakerName")
            }
        }
    }

    var otherNames: String {
        get {
            access(keyPath: \.otherNames)
            return Self.defaults.string(forKey: "otherNames") ?? ""
        }
        set {
            withMutation(keyPath: \.otherNames) {
                Self.defaults.set(newValue, forKey: "otherNames")
            }
        }
    }

    var micOnly: Bool {
        get {
            access(keyPath: \.micOnly)
            return Self.defaults.bool(forKey: "micOnly")
        }
        set {
            withMutation(keyPath: \.micOnly) {
                Self.defaults.set(newValue, forKey: "micOnly")
            }
            if newValue {
                systemOnly = false
            }
        }
    }

    var systemOnly: Bool {
        get {
            access(keyPath: \.systemOnly)
            return Self.defaults.bool(forKey: "systemOnly")
        }
        set {
            withMutation(keyPath: \.systemOnly) {
                Self.defaults.set(newValue, forKey: "systemOnly")
            }
            if newValue {
                micOnly = false
            }
        }
    }

    var multilingual: Bool {
        get {
            access(keyPath: \.multilingual)
            return Self.defaults.bool(forKey: "multilingual")
        }
        set {
            withMutation(keyPath: \.multilingual) {
                Self.defaults.set(newValue, forKey: "multilingual")
            }
        }
    }

    var outputDirectory: String {
        get {
            access(keyPath: \.outputDirectory)
            return Self.defaults.string(forKey: "outputDirectory") ?? ""
        }
        set {
            withMutation(keyPath: \.outputDirectory) {
                Self.defaults.set(newValue, forKey: "outputDirectory")
            }
        }
    }

    var filenamePattern: String {
        get {
            access(keyPath: \.filenamePattern)
            return Self.defaults.string(forKey: "filenamePattern") ?? "{datetime}.md"
        }
        set {
            withMutation(keyPath: \.filenamePattern) {
                Self.defaults.set(newValue, forKey: "filenamePattern")
            }
        }
    }

    var defaultModel: String {
        get {
            access(keyPath: \.defaultModel)
            return Self.defaults.string(forKey: "defaultModel") ?? "mlx-community/parakeet-tdt-0.6b-v2"
        }
        set {
            withMutation(keyPath: \.defaultModel) {
                Self.defaults.set(newValue, forKey: "defaultModel")
            }
        }
    }

    var dumpAudio: Bool {
        get {
            access(keyPath: \.dumpAudio)
            return Self.defaults.bool(forKey: "dumpAudio")
        }
        set {
            withMutation(keyPath: \.dumpAudio) {
                Self.defaults.set(newValue, forKey: "dumpAudio")
            }
        }
    }

    // MARK: - Computed Helpers

    var resolvedOutputDirectory: String {
        if outputDirectory.isEmpty {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                .first?.path ?? NSHomeDirectory()
        }
        return outputDirectory
    }

    var otherNamesList: [String] {
        otherNames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func buildConfig() -> LivekeetConfig {
        LivekeetConfig(
            outputDirectory: resolvedOutputDirectory,
            filenamePattern: filenamePattern,
            speakerName: speakerName.isEmpty ? "Me" : speakerName,
            defaultModel: defaultModel,
            otherNames: otherNamesList,
            micOnly: micOnly,
            systemOnly: systemOnly,
            multilingual: multilingual,
            dumpAudio: dumpAudio
        )
    }
}
