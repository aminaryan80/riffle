import Foundation

/// Casiez et al.'s 1€ filter: heavy smoothing while the signal is slow (a
/// fixation jitters by tens of points at 30 Hz) and almost none while it is
/// fast (a saccade must land immediately or the highlight lags the eye).
struct OneEuroFilter {
    /// Cutoff at rest, in Hz. Lower = steadier fixation, more lag.
    var minCutoff: Double
    /// How quickly the cutoff opens with speed, per point/second.
    var beta: Double
    /// Cutoff for the derivative estimate, in Hz.
    var derivativeCutoff: Double

    private var lastValue: Double?
    private var lastDerivative = 0.0
    private var lastTime: TimeInterval?

    // Tuned for gaze at 30 Hz: fixation jitter of ~40 pt (≈1200 pt/s frame to
    // frame) adds under 2 Hz of cutoff, a saccade across half a screen adds
    // tens of Hz, so one is smoothed away and the other followed in ~2 frames.
    init(minCutoff: Double = 0.6, beta: Double = 0.0015, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func reset() {
        lastValue = nil
        lastDerivative = 0
        lastTime = nil
    }

    mutating func filter(_ value: Double, at time: TimeInterval) -> Double {
        guard let previous = lastValue, let previousTime = lastTime, time > previousTime else {
            lastValue = value
            lastTime = time
            return value
        }
        let dt = time - previousTime
        let rawDerivative = (value - previous) / dt
        let derivative = Self.lowPass(rawDerivative, previous: lastDerivative,
                                      alpha: Self.alpha(cutoff: derivativeCutoff, dt: dt))
        let cutoff = minCutoff + beta * abs(derivative)
        let filtered = Self.lowPass(value, previous: previous, alpha: Self.alpha(cutoff: cutoff, dt: dt))
        lastValue = filtered
        lastDerivative = derivative
        lastTime = time
        return filtered
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    private static func lowPass(_ value: Double, previous: Double, alpha: Double) -> Double {
        alpha * value + (1 - alpha) * previous
    }
}

struct OneEuroFilter2D {
    private var x: OneEuroFilter
    private var y: OneEuroFilter

    init(minCutoff: Double = 0.6, beta: Double = 0.0015, derivativeCutoff: Double = 1.0) {
        x = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        y = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
    }

    mutating func reset() {
        x.reset()
        y.reset()
    }

    mutating func filter(_ point: CGPoint, at time: TimeInterval) -> CGPoint {
        CGPoint(x: x.filter(point.x, at: time), y: y.filter(point.y, at: time))
    }
}
