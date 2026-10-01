import Foundation

/// One calibration observation: what the camera measured while the user was
/// (told to be) looking at `target`.
struct GazeCalibrationSample: Codable {
    let inputs: [Double]
    let target: CGPoint

    init(features: GazeFeatures, target: CGPoint) {
        inputs = features.regressionInputs
        self.target = target
    }
}

/// Linear ridge regression from standardized face/eye features to screen
/// points. Tiny by design: a handful of coefficients that nine fixation
/// points can pin down. Gaze angle maps near-linearly to screen position
/// over a monitor's field of view, so the linear model is a reasonable fit;
/// what it cannot do is compensate for head movement it never saw.
struct GazeCalibrationModel: Codable {
    let means: [Double]
    let scales: [Double]
    /// Coefficients for x and y: bias first, then one per standardized input.
    let weightsX: [Double]
    let weightsY: [Double]
    /// Mean distance (points) between prediction and target over the
    /// calibration samples. Optimistic — it is training error — but enough
    /// to tell a good calibration from a failed one.
    let meanErrorPoints: Double
    let sampleCount: Int
    let createdAt: Date

    func predict(_ features: GazeFeatures) -> CGPoint {
        let x = Self.design(features.regressionInputs, means: means, scales: scales)
        return CGPoint(x: Self.dot(x, weightsX), y: Self.dot(x, weightsY))
    }

    /// Shrinkage relative to the (standardized) feature energy. Head yaw and
    /// pupil offset are collinear — people turn their head *and* their eyes
    /// toward a target — and ridge is what keeps that from exploding.
    static let ridgeFraction = 0.1

    static func fit(_ samples: [GazeCalibrationSample]) -> GazeCalibrationModel? {
        guard let first = samples.first else { return nil }
        let k = first.inputs.count
        let n = samples.count
        guard n >= k + 1, samples.allSatisfy({ $0.inputs.count == k }) else { return nil }

        var means = [Double](repeating: 0, count: k)
        var scales = [Double](repeating: 1, count: k)
        for j in 0..<k {
            let column = samples.map { $0.inputs[j] }
            let mean = column.reduce(0, +) / Double(n)
            let variance = column.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)
            let floor = j < GazeFeatures.scaleFloors.count ? GazeFeatures.scaleFloors[j] : 1e-3
            means[j] = mean
            scales[j] = max(variance.squareRoot(), floor)
        }

        // Normal equations: (XᵀX + λD) w = XᵀY, with D zero for the bias so
        // the intercept is never shrunk.
        let dim = k + 1
        var ata = [[Double]](repeating: [Double](repeating: 0, count: dim), count: dim)
        var atx = [Double](repeating: 0, count: dim)
        var aty = [Double](repeating: 0, count: dim)
        for s in samples {
            let row = design(s.inputs, means: means, scales: scales)
            for i in 0..<dim {
                atx[i] += row[i] * s.target.x
                aty[i] += row[i] * s.target.y
                for j in 0..<dim { ata[i][j] += row[i] * row[j] }
            }
        }
        let lambda = ridgeFraction * Double(n)
        for i in 1..<dim { ata[i][i] += lambda }

        guard let wx = solve(ata, atx), let wy = solve(ata, aty) else { return nil }

        var error = 0.0
        for s in samples {
            let row = design(s.inputs, means: means, scales: scales)
            let dx = dot(row, wx) - s.target.x
            let dy = dot(row, wy) - s.target.y
            error += (dx * dx + dy * dy).squareRoot()
        }

        return GazeCalibrationModel(
            means: means,
            scales: scales,
            weightsX: wx,
            weightsY: wy,
            meanErrorPoints: error / Double(n),
            sampleCount: n,
            createdAt: Date()
        )
    }

    private static func design(_ inputs: [Double], means: [Double], scales: [Double]) -> [Double] {
        var row = [1.0]
        row.reserveCapacity(inputs.count + 1)
        for j in 0..<inputs.count {
            row.append((inputs[j] - means[j]) / scales[j])
        }
        return row
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }

    /// Gaussian elimination with partial pivoting. The system is 8×8; pulling
    /// in LAPACK for that would be more code than this.
    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix
        var b = rhs
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            if pivot != col {
                a.swapAt(pivot, col)
                b.swapAt(pivot, col)
            }
            for r in (col + 1)..<n {
                let factor = a[r][col] / a[col][col]
                guard factor != 0 else { continue }
                for c in col..<n { a[r][c] -= factor * a[col][c] }
                b[r] -= factor * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[r]
            for c in (r + 1)..<n { sum -= a[r][c] * x[c] }
            x[r] = sum / a[r][r]
        }
        return x
    }
}

/// Calibrations on disk, one per monitor layout. Raw samples are kept too so
/// a future refinement (e.g. from clicks) can refit instead of starting over.
final class GazeCalibrationStore {
    static let shared = GazeCalibrationStore()

    private struct Entry: Codable {
        var model: GazeCalibrationModel
        var samples: [GazeCalibrationSample]
    }

    private struct File: Codable {
        var layouts: [String: Entry]
    }

    static let fileURL = Config.directory.appendingPathComponent("gaze-calibration.json")

    private var layouts: [String: Entry] = [:]
    private var loaded = false

    func model(forCurrentLayout layoutKey: String = ScreenCoords.displayLayoutKey()) -> GazeCalibrationModel? {
        loadIfNeeded()
        return layouts[layoutKey]?.model
    }

    func save(model: GazeCalibrationModel, samples: [GazeCalibrationSample],
              layoutKey: String = ScreenCoords.displayLayoutKey()) {
        loadIfNeeded()
        layouts[layoutKey] = Entry(model: model, samples: samples)
        write()
    }

    func clear(layoutKey: String = ScreenCoords.displayLayoutKey()) {
        loadIfNeeded()
        layouts[layoutKey] = nil
        write()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        layouts = file.layouts
    }

    private func write() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(File(layouts: layouts)) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
