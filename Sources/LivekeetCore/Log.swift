import Foundation
import os

/// Unified logger using os.Logger — visible in Console.app under com.livekeet.core.
public enum Log {
    private static let logger = Logger(subsystem: "com.livekeet.core", category: "pipeline")

    public static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
