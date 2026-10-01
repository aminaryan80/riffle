import AppKit
import QuartzCore

/// Full-screen calibration: a dot visits a grid of points on every monitor
/// while face/eye features are recorded against each, then a ridge model is
/// fit and previewed live so the user can judge it before trusting it.
/// Esc cancels at any point. Main-thread only.
final class GazeCalibrationFlow {
    private let source: VisionGazeSource
    private var completion: (() -> Void)?
    private var windows: [CalibrationWindow] = []
    private var previousApp: NSRunningApplication?

    private struct Target {
        let point: CGPoint   // CG (top-left) global coordinates
    }

    private enum Phase {
        case intro
        case moving
        case settling
        case collecting
        case preview
        case done
    }

    private var phase: Phase = .intro
    private var targets: [Target] = []
    private var targetIndex = 0
    private var samples: [GazeCalibrationSample] = []
    private var collected: [GazeCalibrationSample] = []
    private var failedTargets = 0
    private var timer: Timer?
    private var introStart: TimeInterval = 0
    private var faceSeenSince: TimeInterval?
    private var phaseStart: TimeInterval = 0
    private var previewModel: GazeCalibrationModel?
    private var previewFilter = OneEuroFilter2D()

    /// Points per screen: 3×3 alone, corners+center when there are several —
    /// fifteen dots across three monitors is already a lot to sit through.
    private static let singleScreenGrid: [CGFloat] = [0.1, 0.5, 0.9]
    private static let edgeInset: CGFloat = 0.1
    private static let introMinimum: TimeInterval = 2.0
    private static let faceStableBeforeStart: TimeInterval = 0.6
    private static let moveDuration: TimeInterval = 0.35
    /// The eye needs a moment to land after a saccade; frames during that
    /// would be labelled with the new target while still on the old one.
    private static let settleDuration: TimeInterval = 0.6
    private static let framesPerTarget = 12
    private static let minFramesPerTarget = 6
    private static let collectTimeout: TimeInterval = 3.5
    private static let minConfidence = 0.5
    private static let previewDuration: TimeInterval = 12
    private static let failureDisplay: TimeInterval = 3.5

    init(source: VisionGazeSource) {
        self.source = source
    }

    func start(completion: @escaping () -> Void) {
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        buildTargets()
        buildWindows()
        source.onFeatures = { [weak self] features in self?.handle(features) }
        introStart = CACurrentMediaTime()
        phase = .intro
        showText(
            title: "Gaze calibration",
            body: "Follow the dot with your eyes. Sit as you normally do and keep your head still.\n"
                + "Press Esc to cancel."
        )
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: - Setup

    private func buildTargets() {
        let screens = NSScreen.screens
        let fractions: [(CGFloat, CGFloat)]
        if screens.count == 1 {
            var grid: [(CGFloat, CGFloat)] = []
            for (row, y) in Self.singleScreenGrid.enumerated() {
                // Snake order: the dot never jumps across the whole screen.
                let xs = row.isMultiple(of: 2) ? Self.singleScreenGrid : Self.singleScreenGrid.reversed()
                for x in xs { grid.append((x, y)) }
            }
            fractions = grid
        } else {
            let lo = Self.edgeInset, hi = 1 - Self.edgeInset
            fractions = [(lo, lo), (hi, lo), (0.5, 0.5), (hi, hi), (lo, hi)]
        }
        targets = screens.sorted { $0.frame.minX < $1.frame.minX }.flatMap { screen in
            fractions.map { fx, fy -> Target in
                // Fractions are top-down; AppKit screen frames are bottom-up.
                let appKit = NSPoint(
                    x: screen.frame.minX + screen.frame.width * fx,
                    y: screen.frame.maxY - screen.frame.height * fy
                )
                return Target(point: ScreenCoords.cgPoint(fromAppKit: appKit))
            }
        }
    }

    private func buildWindows() {
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let window = CalibrationWindow(screen: screen)
            window.onKeyDown = { [weak self] key in self?.keyDown(key) }
            window.onMouseDown = { [weak self] in self?.mouseDown() }
            windows.append(window)
            if screen == mouseScreen {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
        }
    }

    // MARK: - Input

    private func keyDown(_ keyCode: UInt16) {
        if keyCode == 53 { // Esc
            finish()
            return
        }
        if phase == .preview { finish() }
    }

    private func mouseDown() {
        if phase == .preview { finish() }
    }

    // MARK: - State machine

    private func tick() {
        let now = CACurrentMediaTime()
        switch phase {
        case .intro:
            updateStatus()
            guard now - introStart >= Self.introMinimum,
                  let since = faceSeenSince, now - since >= Self.faceStableBeforeStart
            else { return }
            hideText()
            beginTarget(0)
        case .collecting:
            if now - phaseStart >= Self.collectTimeout {
                finishTarget()
            }
        case .preview:
            if now - phaseStart >= Self.previewDuration { finish() }
        case .moving, .settling, .done:
            break
        }
    }

    private func beginTarget(_ index: Int) {
        guard index < targets.count else {
            fitAndPreview()
            return
        }
        targetIndex = index
        collected = []
        phase = .moving
        let target = targets[index]
        for window in windows { window.view.moveDot(to: target.point, duration: Self.moveDuration) }
        setStatus("Dot \(index + 1) of \(targets.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.moveDuration) { [weak self] in
            guard let self, phase == .moving else { return }
            phase = .settling
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) { [weak self] in
                guard let self, phase == .settling else { return }
                phase = .collecting
                phaseStart = CACurrentMediaTime()
            }
        }
    }

    private func finishTarget() {
        if collected.count >= Self.minFramesPerTarget {
            samples.append(contentsOf: collected)
        } else {
            failedTargets += 1
        }
        for window in windows { window.view.setDotProgress(0) }
        beginTarget(targetIndex + 1)
    }

    private func handle(_ features: GazeFeatures?) {
        let now = CACurrentMediaTime()
        if let features, features.confidence > 0 {
            if faceSeenSince == nil { faceSeenSince = now }
        } else {
            faceSeenSince = nil
        }

        switch phase {
        case .collecting:
            guard let features, features.confidence >= Self.minConfidence else { return }
            collected.append(GazeCalibrationSample(features: features, target: targets[targetIndex].point))
            let progress = Double(collected.count) / Double(Self.framesPerTarget)
            for window in windows { window.view.setDotProgress(min(progress, 1)) }
            if collected.count >= Self.framesPerTarget { finishTarget() }
        case .preview:
            guard let features, features.confidence > 0, let model = previewModel else { return }
            var point = model.predict(features)
            let bounds = ScreenCoords.desktopBounds()
            point.x = min(max(point.x, bounds.minX), bounds.maxX)
            point.y = min(max(point.y, bounds.minY), bounds.maxY)
            let smoothed = previewFilter.filter(point, at: now)
            for window in windows { window.view.showCrosshair(at: smoothed) }
        default:
            break
        }
    }

    private func fitAndPreview() {
        for window in windows { window.view.hideDot() }
        setStatus("")
        let succeeded = targets.count - failedTargets
        let enough = Double(succeeded) >= Double(targets.count) * 0.7
        guard enough, let model = GazeCalibrationModel.fit(samples) else {
            let reason = enough
                ? "The measurements didn't fit a usable model."
                : "Your eyes were lost on \(failedTargets) of \(targets.count) dots."
            fail(reason)
            return
        }
        GazeCalibrationStore.shared.save(model: model, samples: samples)
        previewModel = model
        previewFilter.reset()
        phase = .preview
        phaseStart = CACurrentMediaTime()
        let error = Int(model.meanErrorPoints.rounded())
        showText(
            title: "Calibrated",
            body: "Average error about \(error) pt on the calibration dots. The ring now follows your gaze — "
                + "look around to check it.\nPress any key or click to finish."
        )
    }

    private func fail(_ reason: String) {
        phase = .done
        showText(
            title: "Calibration didn't work",
            body: reason + "\nFace the camera, avoid strong backlight, and try again."
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.failureDisplay) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        phase = .done
        timer?.invalidate()
        timer = nil
        source.onFeatures = nil
        for window in windows { window.orderOut(nil) }
        windows = []
        // Give focus back unless Riffle has a window of its own open (Settings).
        let riffleHasWindow = NSApp.windows.contains { $0.isVisible && !($0 is CalibrationWindow) && !($0 is NSPanel) }
        if !riffleHasWindow, let previousApp,
           previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            _ = previousApp.activate(options: [])
        }
        completion()
    }

    // MARK: - Text

    private func showText(title: String, body: String) {
        for window in windows { window.view.showText(title: title, body: body) }
        updateStatus()
    }

    private func hideText() {
        for window in windows { window.view.showText(title: nil, body: nil) }
    }

    private func setStatus(_ text: String) {
        for window in windows { window.view.setStatus(text) }
    }

    private func updateStatus() {
        guard phase == .intro else { return }
        switch source.state {
        case .off, .starting: setStatus("Starting camera…")
        case .noCamera: setStatus("No camera found. Connect one, or pick another in Settings.")
        case .noFace: setStatus("Looking for your face…")
        case .tracking: setStatus(faceSeenSince == nil ? "Eyes not visible yet…" : "Face found — starting")
        }
    }
}

// MARK: - Windows

private final class CalibrationWindow: NSWindow {
    let view: CalibrationView
    var onKeyDown: ((UInt16) -> Void)?
    var onMouseDown: (() -> Void)?

    init(screen: NSScreen) {
        view = CalibrationView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.9)
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = false
        contentView = view
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event.keyCode)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}

private final class CalibrationView: NSView {
    private let dot = CAShapeLayer()
    private let crosshair = CAShapeLayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    private static let dotRadius: CGFloat = 16
    private static let crosshairRadius: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        dot.path = CGPath(ellipseIn: CGRect(x: -Self.dotRadius, y: -Self.dotRadius,
                                            width: Self.dotRadius * 2, height: Self.dotRadius * 2), transform: nil)
        dot.fillColor = NSColor.controlAccentColor.cgColor
        dot.strokeColor = NSColor.white.cgColor
        dot.lineWidth = 3
        dot.isHidden = true
        layer?.addSublayer(dot)

        crosshair.path = CGPath(ellipseIn: CGRect(x: -Self.crosshairRadius, y: -Self.crosshairRadius,
                                                  width: Self.crosshairRadius * 2, height: Self.crosshairRadius * 2),
                                transform: nil)
        crosshair.fillColor = nil
        crosshair.strokeColor = NSColor.controlAccentColor.cgColor
        crosshair.lineWidth = 3
        crosshair.isHidden = true
        layer?.addSublayer(crosshair)

        titleLabel.font = .boldSystemFont(ofSize: 28)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        bodyLabel.font = .systemFont(ofSize: 18)
        bodyLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        bodyLabel.alignment = .center
        bodyLabel.preferredMaxLayoutWidth = 640
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        statusLabel.alignment = .center
        for label in [titleLabel, bodyLabel, statusLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: frame.height * 0.2),
            bodyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            bodyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -frame.height * 0.08),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showText(title: String?, body: String?) {
        titleLabel.stringValue = title ?? ""
        bodyLabel.stringValue = body ?? ""
        titleLabel.isHidden = title == nil
        bodyLabel.isHidden = body == nil
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    /// `point` is in CG global coordinates; only the screen containing it
    /// shows the dot, the others hide theirs.
    func moveDot(to point: CGPoint, duration: TimeInterval) {
        guard let local = localPoint(fromCG: point) else {
            dot.isHidden = true
            return
        }
        CATransaction.begin()
        if dot.isHidden {
            CATransaction.setDisableActions(true)
            dot.position = local
            dot.isHidden = false
        } else {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            dot.position = local
        }
        dot.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Shrinks the dot as frames are collected, so the wait has a visible end.
    func setDotProgress(_ progress: Double) {
        let scale = 1 - 0.55 * CGFloat(progress)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        dot.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    func hideDot() {
        dot.isHidden = true
    }

    func showCrosshair(at point: CGPoint) {
        guard let local = localPoint(fromCG: point) else {
            crosshair.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        crosshair.position = local
        crosshair.isHidden = false
        CATransaction.commit()
    }

    private func localPoint(fromCG point: CGPoint) -> CGPoint? {
        guard let window else { return nil }
        let screenPoint = ScreenCoords.appKitPoint(fromCG: point)
        guard window.frame.contains(screenPoint) else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return convert(windowPoint, from: nil)
    }
}
