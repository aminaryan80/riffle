import AVFoundation

/// Thin AVCaptureSession wrapper: picks a camera, streams BGRA frames at
/// ≤30 fps on a private queue. Nothing here knows about faces or gaze.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the capture queue for every frame.
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    /// Called on the main thread when the session starts, stops, or fails.
    var onRunningChanged: ((Bool) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "Riffle.Gaze.camera", qos: .userInitiated)
    private var configured = false
    private(set) var isRunning = false

    // MARK: - Permission & devices

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Completion runs on the main thread.
    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func availableCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        }
        var devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices
        // Pre-14 the discovery types above miss USB webcams; the system default
        // at least surfaces whichever one macOS would pick.
        if let fallback = AVCaptureDevice.default(for: .video),
           !devices.contains(where: { $0.uniqueID == fallback.uniqueID }) {
            devices.append(fallback)
        }
        return devices
    }

    // MARK: - Lifecycle

    /// Starts (or re-targets) the session. `startRunning` blocks for a good
    /// fraction of a second, so everything happens on the capture queue.
    func start(deviceID: String?) {
        queue.async { [self] in
            let device = Self.availableCameras().first { $0.uniqueID == deviceID }
                ?? AVCaptureDevice.default(for: .video)
            guard let device else {
                notifyRunning(false)
                return
            }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                session.commitConfiguration()
                notifyRunning(false)
                return
            }
            session.addInput(input)
            if !configured {
                configured = true
                // 720p keeps the eye region ~40 px wide at arm's length — the
                // minimum for a usable pupil position. Higher costs CPU for little gain.
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            session.commitConfiguration()
            Self.capFrameRate(of: device, to: 30)
            if !session.isRunning { session.startRunning() }
            notifyRunning(session.isRunning)
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            notifyRunning(false)
        }
    }

    private static func capFrameRate(of device: AVCaptureDevice, to fps: Int32) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let target = CMTime(value: 1, timescale: fps)
        let supported = device.activeFormat.videoSupportedFrameRateRanges
            .contains { $0.minFrameDuration <= target && target <= $0.maxFrameDuration }
        if supported { device.activeVideoMinFrameDuration = target }
    }

    private func notifyRunning(_ running: Bool) {
        DispatchQueue.main.async {
            self.isRunning = running
            self.onRunningChanged?(running)
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(buffer, CACurrentMediaTime())
    }
}
