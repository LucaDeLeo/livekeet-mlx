import Foundation

/// Resolve the output file path from config and an optional CLI argument.
public func resolveOutputPath(arg: String?, config: LivekeetConfig) -> URL {
    let now = Date()

    if let arg = arg, !arg.isEmpty {
        var url = URL(fileURLWithPath: arg)

        // If it's a directory, use the config filename pattern inside it
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let filename = expandPattern(config.filenamePattern, date: now)
            return url.appendingPathComponent(filename)
        }

        // Add .md extension if missing
        if url.pathExtension.isEmpty {
            url = url.appendingPathExtension("md")
        }
        return url
    }

    // Use config pattern
    let filename = expandPattern(config.filenamePattern, date: now)

    if !config.outputDirectory.isEmpty {
        let dir = NSString(string: config.outputDirectory).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        return dirURL.appendingPathComponent(filename)
    }

    return URL(fileURLWithPath: filename)
}

/// Ensure the output path doesn't overwrite an existing file by appending -2, -3, etc.
public func ensureUniquePath(_ path: URL) -> (path: URL, wasSuffixed: Bool) {
    guard FileManager.default.fileExists(atPath: path.path) else {
        return (path, false)
    }

    let ext = path.pathExtension
    let nameWithoutExt = path.deletingPathExtension().lastPathComponent
    let dir = path.deletingLastPathComponent()

    // Check if name already ends with -N
    var base = nameWithoutExt
    var counter = 2

    if let range = nameWithoutExt.range(of: #"-(\d+)$"#, options: .regularExpression) {
        let numStr = String(nameWithoutExt[nameWithoutExt.index(after: range.lowerBound)...])
        if let num = Int(numStr) {
            base = String(nameWithoutExt[..<range.lowerBound])
            counter = num + 1
        }
    }

    while true {
        let candidate = dir.appendingPathComponent("\(base)-\(counter).\(ext)")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return (candidate, true)
        }
        counter += 1
    }
}

/// Expand {date}, {time}, {datetime} placeholders in a filename pattern.
func expandPattern(_ pattern: String, date: Date) -> String {
    let dateStr = dateOnlyFormatter.string(from: date)
    let timeStr = timeOnlyFormatter.string(from: date)
    let datetimeStr = datetimeFormatter.string(from: date)

    return pattern
        .replacingOccurrences(of: "{date}", with: dateStr)
        .replacingOccurrences(of: "{time}", with: timeStr)
        .replacingOccurrences(of: "{datetime}", with: datetimeStr)
}

// MARK: - Date Formatters

private let dateOnlyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private let timeOnlyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH-MM-SS"
    return f
}()

private let datetimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    return f
}()
