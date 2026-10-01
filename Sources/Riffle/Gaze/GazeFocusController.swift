import AppKit
import QuartzCore

/// Turns gaze samples into focus changes. Two ways in:
///  - a shortcut with the `gaze` scope: hold it, a frame follows your gaze
///    from window to window, release to focus (driven by `SwitcherController`);
///  - dwell: with it enabled, looking at a window for a while focuses it,
///    unless you are typing or mousing — glancing at the clock mid-sentence
///    must never redirect keystrokes.
/// Main-thread only.
final class GazeFocusController {
    static let shared = GazeFocusController()

    /// Dwell must never fire under an open switcher list.
    var isSwitcherActive: () -> Bool = { false }

    private let vision = VisionGazeSource()
    private let highlight = GazeHighlightPanel()
    private var calibration: GazeCalibrationFlow?

    /// The backend as seen by callers that only need gaze points.
    var source: GazeSource { vision }
    /// Settings and calibration need the webcam specifics.
    var visionSource: VisionGazeSource { vision }

    private var latest: GazeSample?
    private var lastHitTest: TimeInterval = 0
    /// Each hit-test is a window-server round trip; 15 Hz is plenty for a
    /// frame that follows the eye and well under what 30 fps gaze could drive.
    private static let hitTestInterval: TimeInterval = 1.0 / 15
    /// How far outside every window a gaze point may land and still pick the
    /// nearest one (gaps between windows, desktop edges). Roughly 3–4 cm.
    private static let hitTolerance: CGFloat = 160

    // Hold-look-release session.
    private(set) var isHotkeySessionActive = false
    private var sessionTarget: WindowInfo?
    private var sessionTargetSeen: TimeInterval = 0
    /// Keep the last pick this long after gaze wanders off every window, so
    /// a glance at the desktop doesn't make the frame vanish.
    private static let sessionTargetGrace: TimeInterval = 1.5

    // Dwell.
    private var dwellCandidate: CGWindowID?
    private var dwellStart: TimeInterval = 0
    private var lastKeyboardActivity: TimeInterval = 0
    private var lastMouseActivity: TimeInterval = 0
    private var lastMouseLocation: NSPoint = .zero
    private var lastDwellSwitch: TimeInterval = 0
    private static let typingGuard: TimeInterval = 1.0
    private static let mouseGuard: TimeInterval = 0.6
    private static let switchCooldown: TimeInterval = 1.2
    private static let minDwellConfidence = 0.5

    private init() {}

    /// Call once Accessibility is granted (focusing windows needs it).
    func start() {
        Config.shared.onGazeSettingsChanged = { [weak self] _ in self?.applySettings() }
        vision.onSample = { [weak self] sample in self?.handle(sample) }
        applySettings()
    }

    private func applySettings() {
        let settings = Config.shared.gaze
        vision.setCamera(settings.cameraID)
        guard settings.enabled else {
            endHotkeySession()
            resetDwell()
            vision.stop()
            return
        }
        ensureCameraAccess { [weak self] granted in
            guard let self, Config.shared.gaze.enabled else { return }
            if granted {
                if vision.state == .off { vision.start() }
            } else {
                vision.stop()
            }
        }
    }

    /// Prompts only when macOS hasn't asked yet; a denial sends the user to
    /// System Settings (see the Settings window).
    func ensureCameraAccess(_ completion: @escaping (Bool) -> Void) {
        switch CameraCapture.authorizationStatus {
        case .authorized: completion(true)
        case .notDetermined: CameraCapture.requestAccess(completion)
        default: completion(false)
        }
    }

    /// True when a gaze shortcut or dwell can actually do something right now.
    var isReady: Bool {
        Config.shared.gaze.enabled && vision.isCalibrated
            && (vision.state == .tracking || vision.state == .noFace)
    }

    // MARK: - Keyboard / mouse activity (dwell guards)

    /// From the event tap, on every key press.
    func noteKeyboardActivity() {
        lastKeyboardActivity = CACurrentMediaTime()
    }

    private func trackMouseActivity(at now: TimeInterval) {
        let location = NSEvent.mouseLocation
        if hypot(location.x - lastMouseLocation.x, location.y - lastMouseLocation.y) > 2
            || NSEvent.pressedMouseButtons != 0 {
            lastMouseActivity = now
            lastMouseLocation = location
        }
    }

    // MARK: - Hold-look-release session

    /// Returns false when gaze can't serve the shortcut (disabled, no
    /// calibration for this monitor layout, camera unavailable).
    @discardableResult
    func beginHotkeySession() -> Bool {
        guard isReady, calibration == nil else { return false }
        isHotkeySessionActive = true
        sessionTarget = nil
        sessionTargetSeen = 0
        // Seed from the last sample so the frame appears on the key press,
        // not one hit-test interval later.
        if let latest, CACurrentMediaTime() - latest.timestamp < 0.5 {
            updateSessionTarget(for: latest.point, at: CACurrentMediaTime())
        }
        return true
    }

    func commitHotkeySession() {
        guard isHotkeySessionActive else { return }
        let target = sessionTarget
        endHotkeySession()
        if let target { WindowEnumerator.switchTo(target) }
    }

    func cancelHotkeySession() {
        endHotkeySession()
    }

    private func endHotkeySession() {
        isHotkeySessionActive = false
        sessionTarget = nil
        highlight.hide()
    }

    private func updateSessionTarget(for point: CGPoint, at now: TimeInterval) {
        let windows = WindowEnumerator.visibleWindows()
        if let hit = Self.window(at: point, in: windows) {
            sessionTarget = hit
            sessionTargetSeen = now
            highlight.show(around: hit.frame)
        } else if sessionTarget != nil, now - sessionTargetSeen > Self.sessionTargetGrace {
            sessionTarget = nil
            highlight.hide()
        }
    }

    // MARK: - Samples

    private func handle(_ sample: GazeSample) {
        latest = sample
        guard sample.timestamp - lastHitTest >= Self.hitTestInterval else { return }
        lastHitTest = sample.timestamp
        if isHotkeySessionActive {
            updateSessionTarget(for: sample.point, at: sample.timestamp)
        } else if Config.shared.gaze.dwellEnabled {
            updateDwell(sample)
        }
    }

    private func updateDwell(_ sample: GazeSample) {
        let now = sample.timestamp
        trackMouseActivity(at: now)
        guard calibration == nil, !isSwitcherActive() else {
            resetDwell()
            return
        }
        // A blink or half-lost face is not a reason to forget the candidate.
        guard sample.confidence >= Self.minDwellConfidence else { return }

        let windows = WindowEnumerator.visibleWindows()
        guard let hit = Self.window(at: sample.point, in: windows) else {
            resetDwell()
            return
        }
        // Topmost on screen is the focused window: nothing to do. This is also
        // the resting state right after a switch, so no extra hysteresis needed.
        if hit.windowID == windows.first?.windowID {
            resetDwell()
            return
        }
        if dwellCandidate != hit.windowID {
            dwellCandidate = hit.windowID
            dwellStart = now
            return
        }
        guard now - dwellStart >= Config.shared.gaze.dwellSeconds else { return }
        // Busy hands: restart the dwell so a switch needs a fresh, deliberate
        // look after the typing or mousing stops — never the instant it does.
        guard now - lastKeyboardActivity > Self.typingGuard,
              now - lastMouseActivity > Self.mouseGuard,
              now - lastDwellSwitch > Self.switchCooldown
        else {
            dwellStart = now
            return
        }
        lastDwellSwitch = now
        resetDwell()
        highlight.flash(around: hit.frame)
        WindowEnumerator.switchTo(hit)
    }

    private func resetDwell() {
        dwellCandidate = nil
        dwellStart = 0
    }

    // MARK: - Hit-testing

    /// Topmost window containing the point; failing that, the nearest window
    /// within `hitTolerance` measured to its edge (not its center, which
    /// would penalize big windows). `windows` must be front to back.
    static func window(at point: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        if let hit = windows.first(where: { $0.frame.contains(point) }) { return hit }
        var best: (window: WindowInfo, distance: CGFloat)?
        for window in windows {
            let f = window.frame
            let dx = max(f.minX - point.x, 0, point.x - f.maxX)
            let dy = max(f.minY - point.y, 0, point.y - f.maxY)
            let distance = hypot(dx, dy)
            guard distance <= hitTolerance else { continue }
            if best == nil || distance < best!.distance { best = (window, distance) }
        }
        return best?.window
    }

    // MARK: - Calibration

    /// Runs the full-screen calibration. Enables gaze tracking first if needed
    /// (the flow itself waits for the camera to come up). Camera permission is
    /// settled before anything goes full-screen, or the system prompt would
    /// end up underneath the calibration window.
    func calibrate() {
        guard calibration == nil else { return }
        ensureCameraAccess { [weak self] granted in
            guard let self, calibration == nil else { return }
            guard granted else {
                NSSound.beep()
                return
            }
            if !Config.shared.gaze.enabled {
                var settings = Config.shared.gaze
                settings.enabled = true
                Config.shared.setGaze(settings)
            }
            endHotkeySession()
            resetDwell()
            let flow = GazeCalibrationFlow(source: vision)
            calibration = flow
            flow.start { [weak self] in
                self?.calibration = nil
                self?.vision.reloadCalibration()
            }
        }
    }
}
