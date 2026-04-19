import Foundation

enum AudioAnalysis {
    static func rms<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        var sumSquares: Float = 0
        var count: Int = 0
        for s in samples {
            sumSquares += s * s
            count += 1
        }
        return count > 0 ? sqrt(sumSquares / Float(count)) : 0
    }
}
