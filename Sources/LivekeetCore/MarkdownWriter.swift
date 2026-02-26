import Foundation

/// Writes timestamped markdown transcription output.
public actor MarkdownWriter {
    private let path: URL
    private let startDate: Date
    private var fileHandle: FileHandle?

    public init(path: URL) throws {
        self.path = path
        self.startDate = Date()

        // Create the file with header
        let header = "# Transcription - \(Self.formatDateTime(Date()))\n\n"
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path.path, contents: header.data(using: .utf8))
        self.fileHandle = try FileHandle(forWritingTo: path)
        fileHandle?.seekToEndOfFile()
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Write a transcription segment.
    public func writeSegment(time: Date, speaker: String, text: String) {
        let timestamp = Self.formatTime(time)
        let line = "[\(timestamp)] **\(speaker)**: \(text)\n"
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
            // Also print to console (without markdown bold)
            let console = "[\(timestamp)] \(speaker): \(text)"
            print(console)
        }
    }

    /// Rewrite the entire transcript file with updated speaker labels.
    /// Uses atomic write via a temp file to prevent data loss on crash.
    public func rewriteAll(segments: [(timestamp: String, speaker: String, text: String)]) {
        guard fileHandle != nil else { return }

        // Build content in memory
        var content = "# Transcription - \(Self.formatDateTime(startDate))\n\n"
        for segment in segments {
            content += "[\(segment.timestamp)] **\(segment.speaker)**: \(segment.text)\n"
        }

        guard let data = content.data(using: .utf8) else { return }

        // Atomic write: write to temp file, then replace original
        let tempURL = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tempURL)
            // Reopen file handle for appending
            try? fileHandle?.close()
            fileHandle = try FileHandle(forWritingTo: path)
            fileHandle?.seekToEndOfFile()
        } catch {
            // Fall back to truncate-and-rewrite
            try? FileManager.default.removeItem(at: tempURL)
            fileHandle?.seek(toFileOffset: 0)
            fileHandle?.truncateFile(atOffset: 0)
            fileHandle?.write(data)
        }
    }

    /// Write the footer when recording ends.
    public func writeFooter() {
        let footer = "\n---\n*Ended: \(Self.formatDateTime(Date()))*\n"
        if let data = footer.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    // MARK: - Formatting

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func formatDateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }
}
