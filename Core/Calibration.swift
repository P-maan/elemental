//  Calibration.swift — learning how the model is wrong here, so it can be
//  corrected when there is nothing to check it against.
//
//  Observation.swift fixes the forecast against a live METAR. That needs a
//  network, and it only helps while a station is reporting. This is the other
//  half: every time both sources are in hand, the pair is a labelled training
//  example — the model's prediction and the observed truth, for free. Keep
//  enough of them and you can learn how this particular model errs at this
//  particular place, and apply that correction offline.
//
//  What this is NOT
//  ----------------
//  This is not a weather model and cannot become one. It cannot predict
//  anything the forecast does not already contain, it does not look at the
//  atmosphere, and with a week of data it knows very little. What it does is
//  bias correction — the standard, boring, effective thing you do to a
//  numerical forecast when you have observations to compare against. Two small
//  fits, four parameters each:
//
//    cloud     where the model puts cover by altitude vs where it actually is.
//              Ridge-regularised least squares, one fit per band. This is the
//              Greater Noida failure: 98% high cirrus forecast against 44% low
//              and 31% mid observed. Systematic, and therefore learnable.
//
//    precip    P(anything is actually falling | forecast mm, forecast
//              probability, WMO code). Logistic, fitted by IRLS. The forecast
//              claiming 0.10mm and code 51 turns out to mean "raining" a small
//              fraction of the time, and how small is a local fact.
//
//    thunder   P(thunder observed | CAPE, lifted index, code). The useful CAPE
//              threshold is a property of the climate, not a constant — monsoon
//              Noida sits at 2000-4000 J/kg on quiet afternoons where the same
//              number over Massachusetts would mean something. Learning it per
//              location is the only way that comes out right in both places.
//
//  Safety
//  ------
//  A bad fit must never be worse than no fit, so: nothing applies until there
//  are enough samples AND both outcomes have been seen; corrections are clamped
//  to plausible ranges; and the direction is asymmetric in the same way the
//  live reconcile is. A learned low probability SUPPRESSES precipitation the
//  model claimed. A learned high probability never INVENTS precipitation the
//  model did not — being wrongly dry is a missing effect, being wrongly wet is
//  rain running down a window on a clear day, and those are not equally bad.

import Foundation

// MARK: - One labelled example

/// A model forecast and the observation that turned out to be true.
struct WeatherSample: Codable {
    /// Observation epoch. Also the dedupe key — METAR is issued every half
    /// hour and the poller runs every ten minutes, so the same report would
    /// otherwise be recorded three times and count triple in the fit.
    var t: Double

    // model side
    var mLow: Float = 0, mMid: Float = 0, mHigh: Float = 0
    var mPrecip: Float = 0          // mm
    var mPrecipProb: Float = 0      // %
    var mCape: Float = 0
    var mLifted: Float = 0
    var mCodePrecip: Float = 0      // 1 if the WMO code claims precipitation
    var mCodeThunder: Float = 0

    // observed side
    var oLow: Float = 0, oMid: Float = 0, oHigh: Float = 0
    var oPrecip: Float = 0          // 1 / 0
    var oThunder: Float = 0         // 1 / 0
}

/// Four learned weights plus how many examples went into them.
struct Fit: Codable {
    var w: [Float] = [0, 0, 0, 0]
    var n: Int = 0
    var usable: Bool { n > 0 }
    func eval(_ x: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(4, x.count) { s += w[i] * x[i] }
        return s
    }
    func probability(_ x: [Float]) -> Float { 1 / (1 + exp(-eval(x))) }
}

// MARK: - The store

/// Everything learned about one location.
struct Calibration: Codable {
    var key = ""
    var samples: [WeatherSample] = []
    var cloudLow = Fit(), cloudMid = Fit(), cloudHigh = Fit()
    var precip = Fit(), thunder = Fit()
    var fittedAt: Double = 0
    var fittedCount: Int = 0

    /// A month of half-hourly reports. Long enough to see a season turn over,
    /// short enough that the file stays tiny and the fit tracks a changing
    /// climate rather than averaging over one.
    static let maxSamples = 1500

    // Enough examples that a fit means something, and — for the two
    // classifiers — enough of the RARE outcome specifically. Fifty dry
    // afternoons and no wet one teaches nothing except "always dry", which
    // fits perfectly and is useless.
    static let minCloud = 40
    static let minPrecip = 60, minPrecipPositive = 8
    static let minThunder = 90, minThunderPositive = 5

    var summary: String {
        let wet = samples.filter { $0.oPrecip > 0.5 }.count
        let ts  = samples.filter { $0.oThunder > 0.5 }.count
        var lines = [String(format: "%@: %d samples (%d wet, %d thunder)",
                            key, samples.count, wet, ts)]
        lines.append("  cloud   " + (cloudLow.usable
            ? String(format: "fitted on %d", cloudLow.n)
            : String(format: "learning, %d/%d", samples.count, Self.minCloud)))
        lines.append("  precip  " + (precip.usable
            ? String(format: "fitted on %d", precip.n)
            : String(format: "learning, %d/%d samples and %d/%d wet",
                     samples.count, Self.minPrecip, wet, Self.minPrecipPositive)))
        lines.append("  thunder " + (thunder.usable
            ? String(format: "fitted on %d", thunder.n)
            : String(format: "learning, %d/%d samples and %d/%d thunder",
                     samples.count, Self.minThunder, ts, Self.minThunderPositive)))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Feature vectors
//
// Kept in one place because a fit is only valid against the exact features it
// was trained on, and the two call sites (fitting, applying) have to agree
// exactly. Scaled to roughly unit range so the solver is well conditioned.

private enum Features {
    static func cloud(_ lo: Float, _ mid: Float, _ hi: Float) -> [Float] {
        [lo / 100, mid / 100, hi / 100, 1]
    }
    static func precip(_ mm: Float, _ prob: Float, _ codeSaysPrecip: Float) -> [Float] {
        [log(1 + max(0, mm)), prob / 100, codeSaysPrecip, 1]
    }
    static func thunder(_ cape: Float, _ lifted: Float, _ codeSaysThunder: Float) -> [Float] {
        [cape / 2000, max(0, -lifted) / 6, codeSaysThunder, 1]
    }
}

// MARK: - Solvers

private enum Solve {

    /// Ridge-regularised least squares on four features.
    ///
    /// Ridge rather than plain: the three cloud bands are correlated — a
    /// forecast with lots of mid usually has some low — and correlated columns
    /// make the normal equations near-singular, which produces enormous
    /// weights that fit the noise and predict nonsense on anything new.
    static func ridge(_ X: [[Float]], _ y: [Float], lambda: Float = 0.02) -> [Float]? {
        guard X.count == y.count, X.count >= 8 else { return nil }
        var A = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var b = [Double](repeating: 0, count: 4)
        for (row, target) in zip(X, y) {
            for i in 0..<4 {
                b[i] += Double(row[i] * target)
                for j in 0..<4 { A[i][j] += Double(row[i] * row[j]) }
            }
        }
        // Scaled to the data's OWN magnitude, not to the sample count.
        // Multiplying by n means every extra example strengthens the penalty as
        // fast as it strengthens the evidence, so the fit never escapes the
        // prior no matter how much it sees. With 400 samples that put the
        // penalty term above the data term and shrank the weights to nearly
        // zero — the self-test caught it as a mid-cloud fit no better than the
        // raw forecast.
        //
        // Not applied to the intercept: penalising that just biases every
        // prediction toward zero, which for a cover percentage means
        // "always clear".
        var diag: Double = 0
        for i in 0..<3 { diag += A[i][i] }
        let penalty = Double(lambda) * diag / 3
        for i in 0..<3 { A[i][i] += penalty }
        A[3][3] += 1e-6
        return gauss(A, b).map { $0.map(Float.init) }
    }

    /// Logistic regression by iteratively reweighted least squares.
    ///
    /// Newton's method on the log-likelihood: at each step, solve a weighted
    /// least-squares problem where each example's weight is p(1-p) — how
    /// uncertain the current model is about it. Converges in a handful of
    /// iterations where plain gradient descent needs thousands and a learning
    /// rate nobody wants to tune.
    static func logistic(_ X: [[Float]], _ y: [Float], lambda: Float = 1.0) -> [Float]? {
        guard X.count == y.count, X.count >= 16 else { return nil }
        var w = [Double](repeating: 0, count: 4)
        for _ in 0..<25 {
            var A = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
            var g = [Double](repeating: 0, count: 4)
            for (row, target) in zip(X, y) {
                var z: Double = 0
                for i in 0..<4 { z += w[i] * Double(row[i]) }
                let p = 1 / (1 + exp(-max(-30, min(30, z))))
                let r = p * (1 - p) + 1e-6                    // Fisher weight
                let e = Double(target) - p
                for i in 0..<4 {
                    g[i] += Double(row[i]) * e
                    for j in 0..<4 { A[i][j] += r * Double(row[i] * row[j]) }
                }
            }
            for i in 0..<4 { A[i][i] += Double(lambda); g[i] -= Double(lambda) * w[i] }
            guard let step = gauss(A, g) else { return nil }
            var moved: Double = 0
            for i in 0..<4 { w[i] += step[i]; moved += abs(step[i]) }
            if moved < 1e-5 { break }
            if !w.allSatisfy({ $0.isFinite }) { return nil }
        }
        return w.map(Float.init)
    }

    /// 4x4 with partial pivoting. Small and fixed, so this is the whole of it.
    private static func gauss(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0
        for c in 0..<4 {
            var piv = c
            for r in (c + 1)..<4 where abs(A[r][c]) > abs(A[piv][c]) { piv = r }
            guard abs(A[piv][c]) > 1e-12 else { return nil }
            if piv != c { A.swapAt(piv, c); b.swapAt(piv, c) }
            for r in (c + 1)..<4 {
                let f = A[r][c] / A[c][c]
                guard f != 0 else { continue }
                for k in c..<4 { A[r][k] -= f * A[c][k] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: 4)
        for r in stride(from: 3, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<4 { s -= A[r][k] * x[k] }
            x[r] = s / A[r][r]
        }
        return x.allSatisfy { $0.isFinite } ? x : nil
    }
}

// MARK: - Manager

/// Owns the on-disk calibration for whichever place the scene is showing.
///
/// One file per location, keyed on coordinates rounded to about 10km. Noida and
/// Amherst have different climates and the model errs differently in each, so
/// pooling them would learn the average of two things and be right about
/// neither.
final class CalibrationStore {

    private(set) var current = Calibration()
    private var key = ""
    private var dirty = false
    private let queue = DispatchQueue(label: "elemental.calibration", qos: .utility)

    static var directory: URL {
        Config.directory.appendingPathComponent("calibration", isDirectory: true)
    }

    static func key(lat: Double, lon: Double) -> String {
        String(format: "%.1f_%.1f", lat, lon)
    }

    /// Point the store at a location, loading whatever has been learned there.
    func use(lat: Double, lon: Double) {
        let k = Self.key(lat: lat, lon: lon)
        guard k != key else { return }
        flush()
        key = k
        current = Self.load(k) ?? { var c = Calibration(); c.key = k; return c }()
    }

    /// Inject a calibration directly. Only the self-test uses this — it needs
    /// data whose true answer is known, which by definition cannot come from
    /// the real feed.
    func loadForTest(_ c: Calibration) { current = c; key = ""; dirty = false }

    static func load(_ key: String) -> Calibration? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Calibration.self, from: data)
    }

    func flush() {
        guard dirty, !key.isEmpty else { return }
        dirty = false
        let snapshot = current
        let url = Self.directory.appendingPathComponent("\(key).json")
        queue.async {
            try? FileManager.default.createDirectory(at: Self.directory,
                                                     withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Record a forecast/observation pair.
    ///
    /// The model half must be the RAW forecast, before reconcile() has
    /// overwritten it with the observation — otherwise the fit is trained on
    /// the observation predicting itself, learns the identity, and corrects
    /// nothing. This is the single easiest way to get this wrong.
    func record(model: WeatherState, observation o: Observation) {
        guard o.isFresh, o.distanceKm <= 85 else { return }
        let t = Date().timeIntervalSince1970 - o.age
        // Same report seen again on the next poll.
        if let last = current.samples.last, abs(last.t - t) < 60 { return }

        var s = WeatherSample(t: t)
        s.mLow = model.cloudLow; s.mMid = model.cloudMid; s.mHigh = model.cloudHigh
        s.mPrecip = model.precipAmount
        s.mPrecipProb = model.precipProbability
        s.mCape = model.cape
        s.mLifted = model.liftedIndex
        s.mCodePrecip = (model.code >= 51 && model.code <= 86) ? 1 : 0
        s.mCodeThunder = (model.code >= 95 && model.code <= 99) ? 1 : 0
        s.oLow = o.coverLow; s.oMid = o.coverMid; s.oHigh = o.coverHigh
        // Precipitation and thunder are only labelled by a station close enough
        // to speak for here. A shower 70km away is not a label for this place.
        guard o.distanceKm <= 45 else {
            // Cloud-only sample: mark the outcomes unknown by dropping it from
            // the classifiers rather than labelling it dry.
            s.oPrecip = -1; s.oThunder = -1
            append(s); return
        }
        s.oPrecip = (o.raining || o.snowing) ? 1 : 0
        s.oThunder = (o.distanceKm <= 25 && o.thundering) ? 1 : 0
        append(s)
    }

    private func append(_ s: WeatherSample) {
        current.samples.append(s)
        if current.samples.count > Calibration.maxSamples {
            current.samples.removeFirst(current.samples.count - Calibration.maxSamples)
        }
        dirty = true
        // Refitting is cheap but not free, and one more example out of hundreds
        // moves nothing. Every twentieth keeps it current at no real cost.
        if current.samples.count - current.fittedCount >= 20 { refit() }
        flush()
    }

    /// Re-derive every fit from the stored samples.
    func refit() {
        var c = current
        c.fittedCount = c.samples.count
        c.fittedAt = Date().timeIntervalSince1970

        // ---- cloud, one fit per band
        if c.samples.count >= Calibration.minCloud {
            let X = c.samples.map { Features.cloud($0.mLow, $0.mMid, $0.mHigh) }
            func band(_ pick: (WeatherSample) -> Float) -> Fit {
                guard let w = Solve.ridge(X, c.samples.map { pick($0) / 100 }) else { return Fit() }
                return Fit(w: w, n: c.samples.count)
            }
            c.cloudLow  = band { $0.oLow }
            c.cloudMid  = band { $0.oMid }
            c.cloudHigh = band { $0.oHigh }
        }

        // ---- precipitation occurrence
        let wet = c.samples.filter { $0.oPrecip >= 0 }
        let wetPos = wet.filter { $0.oPrecip > 0.5 }.count
        if wet.count >= Calibration.minPrecip && wetPos >= Calibration.minPrecipPositive
            && wetPos < wet.count {
            let X = wet.map { Features.precip($0.mPrecip, $0.mPrecipProb, $0.mCodePrecip) }
            if let w = Solve.logistic(X, wet.map(\.oPrecip)) {
                c.precip = Fit(w: w, n: wet.count)
            }
        }

        // ---- thunder occurrence
        let th = c.samples.filter { $0.oThunder >= 0 }
        let thPos = th.filter { $0.oThunder > 0.5 }.count
        if th.count >= Calibration.minThunder && thPos >= Calibration.minThunderPositive
            && thPos < th.count {
            let X = th.map { Features.thunder($0.mCape, $0.mLifted, $0.mCodeThunder) }
            if let w = Solve.logistic(X, th.map(\.oThunder)) {
                c.thunder = Fit(w: w, n: th.count)
            }
        }

        current = c
        dirty = true
    }

    /// Apply what has been learned. Used when there is no live observation to
    /// defer to — offline, or nowhere near a reporting station.
    ///
    /// Returns a note for the log and the harness, or nil if nothing applied.
    @discardableResult
    func apply(to w: inout WeatherState) -> String? {
        var notes: [String] = []

        if current.cloudLow.usable {
            let x = Features.cloud(w.cloudLow, w.cloudMid, w.cloudHigh)
            // Clamped, and blended rather than replaced. Half weight because
            // this is a correction to a forecast, not a measurement of the sky
            // — at full weight a fit trained on a different season would be
            // trusted as hard as an observation.
            func band(_ f: Fit, _ was: Float) -> Float {
                let pred = max(0, min(100, f.eval(x) * 100))
                return was + (pred - was) * 0.5
            }
            let lo = band(current.cloudLow,  w.cloudLow)
            let md = band(current.cloudMid,  w.cloudMid)
            let hi = band(current.cloudHigh, w.cloudHigh)
            if abs(lo - w.cloudLow) + abs(md - w.cloudMid) + abs(hi - w.cloudHigh) > 6 {
                notes.append(String(format: "cloud %.0f/%.0f/%.0f -> %.0f/%.0f/%.0f",
                                    w.cloudLow, w.cloudMid, w.cloudHigh, lo, md, hi))
            }
            w.cloudLow = lo; w.cloudMid = md; w.cloudHigh = hi
            w.cover = max(w.cover * 0.5, max(lo, max(md, hi)))
        }

        if current.precip.usable && w.isPrecipitating {
            let p = current.precip.probability(
                Features.precip(w.precipAmount, w.precipProbability,
                                (w.code >= 51 && w.code <= 86) ? 1 : 0))
            // Suppress only. A learned high probability never invents rain the
            // forecast did not call for.
            if p < 0.25 {
                notes.append(String(format: "precip suppressed (p=%.2f)", p))
                w.rain = 0; w.showers = 0; w.snow = 0; w.precipitation = 0
            } else if p < 0.5 {
                let k = p / 0.5
                notes.append(String(format: "precip scaled x%.2f (p=%.2f)", k, p))
                w.rain *= k; w.showers *= k; w.snow *= k; w.precipitation *= k
            }
        }

        if current.thunder.usable && (w.code >= 95 && w.code <= 99) {
            let p = current.thunder.probability(
                Features.thunder(w.cape, w.liftedIndex, 1))
            if p < 0.30 {
                notes.append(String(format: "thunder suppressed (p=%.2f)", p))
                w.calibratedThunder = false
            }
        }

        guard !notes.isEmpty else { return nil }
        w.calibratedFrom = current.key
        return notes.joined(separator: "; ")
    }
}
