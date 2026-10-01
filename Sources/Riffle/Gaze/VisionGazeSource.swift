import AppKit
import AVFoundation

/// The dependency-free backend: webcam → Vision face/eye features →
/// calibrated linear mapping → smoothed screen point. Camera frames are
/// processed on the capture queue; everything observable happens on main.
final class VisionGazeSource: GazeSource {
    var onSample: ((GazeSample) -> Void)?
    /// Raw per-frame features for calibration; nil means no face this frame.
    var onFeatures: ((GazeFeatures?) -> Void)?
    var onStateChanged: ((GazeTrackingState) -> Void)?

    private(set) var state: GazeTrackingState = .off {
        didSet { if state != oldValue { onStateChanged?(state) } }
    }

    var isCalibrated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil
    }

    /// Most recent face measurements, for consumers that need them on demand.
    private(set) var latestFeatures: GazeFeatures?

    private let camera = CameraCapture()
    private let tracker = FaceTracker()
    private var cameraID: String?
    private var wantsRunning = false

    // Shared between the capture queue (reads) and main (writes).
    private let lock = NSLock()
    private var model: GazeCalibrationModel?
    private var desktop: CGRect = .zero

    // Capture-queue-only state.
    private var filter = OneEuroFilter2D()
    private var lastFaceSeen: TimeInterval = 0
    /// Gap after which the smoother restarts rather than sliding the cursor
    /// over from wherever the face was last seen.
    private static let faceLossResetInterval: TimeInterval = 0.3

    init() {
        camera.onFrame = { [weak self] buffer, time in self?.process(buffer, at: time) }
        camera.onRunningChanged = { [weak self] running in
            guard let self else { return }
            if running {
                if state == .starting || state == .noCamera { state = .noFace }
            } else {
                state = wantsRunning ? .noCamera : .off
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        // A webcam plugged in after a failed start should just take over.
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceConnected),
            name: AVCaptureDevice.wasConnectedNotification, object: nil
        )
        reloadCalibration()
    }

    // MARK: - GazeSource

    func start() {
        wantsRunning = true
        state = .starting
        camera.start(deviceID: cameraID)
    }

    func stop() {
        wantsRunning = false
        camera.stop()
        state = .off
        latestFeatures = nil
    }

    func setCamera(_ id: String?) {
        guard id != cameraID else { return }
        cameraID = id
        if wantsRunning { start() }
    }

    /// Picks up the calibration for the current monitor layout (if any).
    func reloadCalibration() {
        let next = GazeCalibrationStore.shared.model()
        lock.lock()
        model = next
        desktop = ScreenCoords.desktopBounds()
        lock.unlock()
    }

    @objc private func screensChanged() {
        reloadCalibration()
    }

    @objc private func deviceConnected() {
        if wantsRunning && state == .noCamera { start() }
    }

    // MARK: - Frame processing (capture queue)

    private func process(_ buffer: CVPixelBuffer, at time: TimeInterval) {
        let features = tracker.features(in: buffer, timestamp: time)

        lock.lock()
        let model = model
        let bounds = desktop
        lock.unlock()

        var sample: GazeSample?
        if let features {
            if time - lastFaceSeen > Self.faceLossResetInterval { filter.reset() }
            lastFaceSeen = time
            if let model, features.confidence > 0 {
                var point = model.predict(features)
                point.x = min(max(point.x, bounds.minX), bounds.maxX)
                point.y = min(max(point.y, bounds.minY), bounds.maxY)
                sample = GazeSample(
                    point: filter.filter(point, at: time),
                    confidence: features.confidence,
                    timestamp: time
                )
            }
        }

        DispatchQueue.main.async { [self] in
            guard wantsRunning else { return }
            latestFeatures = features
            state = features == nil ? .noFace : .tracking
            onFeatures?(features)
            if let sample { onSample?(sample) }
        }
    }
}
