import Vision

/// Turns one camera frame into `GazeFeatures` with Apple's Vision framework.
/// Two requests per frame: face rectangles (the only request that reports
/// continuous head pose, revision 3) and landmarks seeded with that face
/// (for eye contours and pupils). Picks the largest face so a passer-by in
/// the background cannot steal the cursor.
final class FaceTracker {
    private let rectangles = VNDetectFaceRectanglesRequest()
    private let landmarks = VNDetectFaceLandmarksRequest()

    /// Eye aspect ratio (height/width) below which the eye counts as closed:
    /// the pupil landmark is then noise and must not move the gaze estimate.
    private static let blinkAspectRatio: CGFloat = 0.14
    /// Eye width in pixels below which the pupil position is too coarse to
    /// trust fully; confidence tapers linearly under it.
    private static let fullConfidenceEyeWidth: CGFloat = 24

    init() {
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3
    }

    /// Returns nil when no face is visible at all.
    func features(in pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> GazeFeatures? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([rectangles])) != nil,
              let face = (rectangles.results ?? []).max(by: { area($0) < area($1) })
        else { return nil }

        landmarks.inputFaceObservations = [face]
        guard (try? handler.perform([landmarks])) != nil,
              let detailed = landmarks.results?.first,
              let marks = detailed.landmarks,
              let leftEye = marks.leftEye, let rightEye = marks.rightEye,
              let leftPupil = marks.leftPupil, let rightPupil = marks.rightPupil
        else {
            // Face seen but eyes not resolved (turned away, occluded): report a
            // zero-confidence frame so callers can distinguish it from "no face".
            return GazeFeatures(
                yaw: face.yaw?.doubleValue ?? 0, pitch: face.pitch?.doubleValue ?? 0,
                roll: face.roll?.doubleValue ?? 0,
                eyeCenter: CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY),
                eyeScale: Double(face.boundingBox.width), pupilOffset: .zero,
                confidence: 0, timestamp: timestamp
            )
        }

        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let left = Self.eyeMetrics(contour: leftEye.pointsInImage(imageSize: imageSize),
                                         pupil: leftPupil.pointsInImage(imageSize: imageSize).first),
              let right = Self.eyeMetrics(contour: rightEye.pointsInImage(imageSize: imageSize),
                                          pupil: rightPupil.pointsInImage(imageSize: imageSize).first)
        else { return nil }

        let center = CGPoint(x: (left.center.x + right.center.x) / 2, y: (left.center.y + right.center.y) / 2)
        let interocular = hypot(right.center.x - left.center.x, right.center.y - left.center.y)
        let eyeWidth = min(left.width, right.width)

        var confidence = Double(min(face.confidence, marks.confidence))
        if left.aspect < Self.blinkAspectRatio || right.aspect < Self.blinkAspectRatio {
            confidence = 0
        } else if eyeWidth < Self.fullConfidenceEyeWidth {
            confidence *= Double(max(eyeWidth, 1) / Self.fullConfidenceEyeWidth)
        }

        return GazeFeatures(
            yaw: face.yaw?.doubleValue ?? 0,
            pitch: face.pitch?.doubleValue ?? 0,
            roll: face.roll?.doubleValue ?? 0,
            eyeCenter: CGPoint(x: center.x / imageSize.width, y: center.y / imageSize.height),
            eyeScale: Double(interocular / imageSize.width),
            pupilOffset: CGPoint(
                x: (left.offset.x + right.offset.x) / 2,
                y: (left.offset.y + right.offset.y) / 2
            ),
            confidence: confidence,
            timestamp: timestamp
        )
    }

    private func area(_ face: VNFaceObservation) -> CGFloat {
        face.boundingBox.width * face.boundingBox.height
    }

    private struct EyeMetrics {
        let center: CGPoint
        let width: CGFloat
        let aspect: CGFloat
        /// Pupil displacement from the eye's center, in eye-widths. Width is
        /// the divisor for both axes: eye *height* collapses when squinting
        /// and would inflate the vertical offset.
        let offset: CGPoint
    }

    private static func eyeMetrics(contour: [CGPoint], pupil: CGPoint?) -> EyeMetrics? {
        guard let pupil, contour.count >= 4 else { return nil }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in contour {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let width = maxX - minX
        guard width > 1 else { return nil }
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        return EyeMetrics(
            center: center,
            width: width,
            aspect: (maxY - minY) / width,
            offset: CGPoint(x: (pupil.x - center.x) / width, y: (pupil.y - center.y) / width)
        )
    }
}
