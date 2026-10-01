import AppKit
import QuartzCore

/// Where the user is looking, in global top-left-origin screen points — the
/// same space as `CGWindow` bounds and `WindowInfo.frame`, so hit-testing
/// against windows needs no conversion.
struct GazeSample {
    let point: CGPoint
    /// 0…1. Low while the face is partially lost or the eyes are closed.
    let confidence: Double
    /// `CACurrentMediaTime()`; monotonic, so staleness checks survive clock changes.
    let timestamp: TimeInterval
}

/// Raw per-frame measurements a webcam backend can produce before any
/// screen mapping. Kept backend-agnostic so the calibration model only ever
/// sees numbers, not Vision types.
struct GazeFeatures {
    /// Head pose in radians, as reported by the face detector.
    let yaw: Double
    let pitch: Double
    let roll: Double
    /// Midpoint between the eyes in normalized image coordinates (0…1).
    /// Stands in for head translation.
    let eyeCenter: CGPoint
    /// Inter-ocular distance over image width: a distance-to-camera proxy.
    let eyeScale: Double
    /// Pupil position relative to the eye's center, normalized by eye
    /// width/height and averaged over both eyes. The eye-in-head signal.
    let pupilOffset: CGPoint
    let confidence: Double
    let timestamp: TimeInterval

    /// Inputs to the screen-mapping regression (bias term added by the model).
    /// Roll is left out: it barely varies during calibration and would only
    /// add an unconstrained coefficient.
    var regressionInputs: [Double] {
        [yaw, pitch, eyeCenter.x, eyeCenter.y, eyeScale, pupilOffset.x, pupilOffset.y]
    }

    /// Minimum standard deviation per input when standardizing. A feature the
    /// user held still during calibration (e.g. head position) would otherwise
    /// get divided by near-zero noise and blow up at prediction time.
    static let scaleFloors: [Double] = [0.02, 0.02, 0.02, 0.02, 0.01, 0.03, 0.03]
}

enum GazeTrackingState: Equatable {
    case off
    case starting
    case noCamera
    case noFace
    case tracking
}

/// A stream of screen-space gaze estimates. The Vision backend implements it
/// today; a hardware or third-party backend (Beam, Tobii) would too, and
/// everything downstream — hit-testing, dwell, highlight — stays the same.
protocol GazeSource: AnyObject {
    /// Delivered on the main thread, only while the face is tracked.
    var onSample: ((GazeSample) -> Void)? { get set }
    var state: GazeTrackingState { get }
    /// True once the source can turn its measurements into screen points.
    var isCalibrated: Bool { get }
    func start()
    func stop()
}

/// AppKit windows use a bottom-left origin on the primary display; the window
/// server (and everything gaze-related here) uses top-left. The primary
/// display is the one with origin (0, 0) in both systems, so flipping about
/// its height converts between them.
enum ScreenCoords {
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
    }

    static func appKitRect(fromCG rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cgRect(fromAppKit rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func appKitPoint(fromCG point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func cgPoint(fromAppKit point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Union of every active display, in CG coordinates. Gaze estimates get
    /// clamped to this so a wild extrapolation still lands on some screen.
    static func desktopBounds() -> CGRect {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displays, &count)
        var union = CGRect.null
        for i in 0..<Int(count) {
            union = union.union(CGDisplayBounds(displays[i]))
        }
        return union.isNull ? CGDisplayBounds(CGMainDisplayID()) : union
    }

    /// Identifies the current monitor arrangement. A calibration maps head and
    /// eye angles to *pixels*, so it is only valid for the layout it was made
    /// on; this key lets one be kept per layout (docked vs. laptop-only).
    static func displayLayoutKey() -> String {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displays, &count)
        return (0..<Int(count))
            .map { i -> String in
                let b = CGDisplayBounds(displays[i])
                return "\(displays[i]):\(Int(b.minX)),\(Int(b.minY)),\(Int(b.width)),\(Int(b.height))"
            }
            .sorted()
            .joined(separator: "|")
    }
}
