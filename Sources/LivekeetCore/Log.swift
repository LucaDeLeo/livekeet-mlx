import Foundation

/// Simple stderr logger used throughout LivekeetCore.
public enum Log {
    public static func info(_ message: String) {
        fputs("\(message)\n", stderr)
    }

    public static func warning(_ message: String) {
        fputs("Warning: \(message)\n", stderr)
    }

    public static func error(_ message: String) {
        fputs("Error: \(message)\n", stderr)
    }
}
