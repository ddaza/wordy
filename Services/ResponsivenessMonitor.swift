import Foundation

/// Samples main-thread scheduling delay while a transcription job runs so the
/// benchmark record can state whether inference degraded UI responsiveness.
@MainActor
final class ResponsivenessMonitor {
    static let interval: TimeInterval = 0.1
    private var timer: Timer?
    private var expected: ContinuousClock.Instant?
    private var samples: [Double] = []

    var isRunning: Bool { timer != nil }

    func start() {
        stop()
        samples.removeAll(keepingCapacity: true)
        expected = .now + .seconds(Self.interval)
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Returns (max, p95) delay in milliseconds beyond the timer interval.
    @discardableResult
    func stop() -> (max: Double, p95: Double)? {
        timer?.invalidate()
        timer = nil
        expected = nil
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return (sorted.last ?? 0, p95)
    }

    private func tick() {
        let now = ContinuousClock.now
        if let expected {
            let delay = max(0, (now - expected).milliseconds)
            if samples.count < 200_000 {
                samples.append(delay)
            }
        }
        expected = now + .seconds(Self.interval)
    }
}
