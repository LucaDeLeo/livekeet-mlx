import Foundation

/// Writes 16kHz mono PCM audio samples to a WAV file.
enum WAVWriter {
    static func write(samples: [Float], sampleRate: Int = 16000, to url: URL) throws {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        // Convert Float samples to Int16
        var pcmData = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            pcmData.append(Data(bytes: &int16, count: 2))
        }

        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize

        var header = Data(capacity: 44)
        header.append(contentsOf: "RIFF".utf8)
        header.append(uint32: fileSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(uint32: 16)  // fmt chunk size
        header.append(uint16: 1)   // PCM format
        header.append(uint16: numChannels)
        header.append(uint32: UInt32(sampleRate))
        header.append(uint32: byteRate)
        header.append(uint16: blockAlign)
        header.append(uint16: bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.append(uint32: dataSize)

        var fileData = header
        fileData.append(pcmData)
        try fileData.write(to: url)
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func append(uint32 value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}
