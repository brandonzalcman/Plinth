import Foundation

/// Turns (time, bytes written) samples into a smoothed bytes-per-second figure.
///
/// Samples closer than `minInterval` are folded into the next one, so the rate does not jitter
/// with every chunk, and an exponential moving average steadies what is left.
public struct DownloadRate: Sendable, Equatable {
    public private(set) var bytesPerSecond: Double?
    private var lastTime: TimeInterval?
    private var lastBytes: Int64 = 0
    private let minInterval: TimeInterval
    private let smoothing: Double

    public init(minInterval: TimeInterval = 0.5, smoothing: Double = 0.35) {
        self.minInterval = minInterval
        self.smoothing = smoothing
    }

    /// Records a sample and returns the current estimate (nil until two samples are far enough apart).
    @discardableResult
    public mutating func sample(bytes: Int64, at time: TimeInterval) -> Double? {
        guard let lastTime else {
            self.lastTime = time; lastBytes = bytes
            return nil
        }
        let elapsed = time - lastTime
        guard elapsed >= minInterval else { return bytesPerSecond }
        let instant = max(0, Double(bytes - lastBytes)) / elapsed
        if let current = bytesPerSecond {
            bytesPerSecond = current + (instant - current) * smoothing
        } else {
            bytesPerSecond = instant
        }
        self.lastTime = time; lastBytes = bytes
        return bytesPerSecond
    }
}
