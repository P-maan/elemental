//  Simulation.swift — the stateful half of the scene.
//
//  Almost everything in the mosaic is a pure function of wall-clock time, which
//  is what lets the renderer idle while covered and resume in a single frame.
//  These are the exceptions: rain streaks, lightning, the shooting star and the
//  glass layer's droplets all integrate, so they live here on the CPU and get a
//  bounded fast-forward when the renderer wakes up.
//
//  Ports drawScene's stateful blocks (roomstand.py:2279-2331) and drawGlass
//  (roomstand.py:2710-2802).

import Foundation

// MARK: - Glass layer particles

/// A droplet clinging to the pane.
///
/// Physical rather than timed. It grows by condensation while it clings; it
/// detaches when its weight beats the surface tension holding it, which is a
/// question of radius, not of a random countdown; falling, it approaches a
/// terminal velocity instead of accelerating forever; and it absorbs the drops
/// it runs into, which is why real rain forms a few fast heavy runs rather
/// than a uniform drizzle of identical beads.
struct GlassDrop {
    var x, y: Float
    var r: Float          // radius, pixels
    var v: Float          // vertical velocity, pixels/sec (negative = thrown up)
    var rCrit: Float      // radius at which surface tension gives out
    var falling: Bool
    /// Sideways velocity. Only spray has any: a drop running down glass is held
    /// by the surface and goes essentially straight.
    var vx: Float = 0
    /// Seconds left as airborne spray. Zero for ordinary drops.
    var splashLife: Float = 0
}
struct GlassSpot { var x, y, r, a: Float }
struct GlassVortex { var x, y, r, t, life, dir: Float }

/// Instance data for one grid-snapped quad in the glass overlay pass.
struct GlassQuad {
    var x, y, r: Float
    var kind: Float      // 0 body, 1 highlight, 2 trail, 3 spot, 4 spot ring, 5 vortex
    var alpha: Float
    var _p0, _p1, _p2: Float
}

// MARK: - Weather in the form a surface feels it

/// What the sky is delivering, in the form that matters to something sitting
/// out in it.
///
/// The WMO code names the hydrometeor; what a dock or a widget then LOOKS like
/// depends on whether that hydrometeor beads, sticks, bounces, freezes or
/// merely settles. Those are different behaviours, not different intensities of
/// one behaviour, which is why this is an enum and not a number.
enum DepositForm {
    /// Nothing falling.
    case none
    /// 0.1-0.5mm drops. Too small to run: they wet a surface evenly and stay
    /// as a matte film, which is why drizzle makes everything look flat rather
    /// than glossy.
    case drizzle
    /// Ordinary rain. Beads, coalesces, runs, and throws spray where it lands.
    case rain
    /// Liquid on arrival, solid within seconds of touching a sub-zero surface.
    /// Builds a clear glaze that does not run and does not look like snow.
    case freezingRain
    /// Ice pellets. They bounce, so they leave a patchy scatter rather than a
    /// film, and they do not stick to a vertical face at all.
    case sleet
    /// Snow. Accumulates on every upward-facing edge, sublimates slowly in dry
    /// air, and melts back from the margins first where the surface is warm.
    case snow
    /// Hail. Hard, fast, and it bounces: the visible signature is the impact
    /// and the spray, not the water left behind.
    case hail
    /// Fog and mist. No impact at all — the water arrives out of the air by
    /// condensation, so it wets everything evenly including undersides.
    case fog
    /// Deposition straight from vapour to ice on a sub-zero surface. A
    /// crystalline bloom that grows outward from edges.
    case frost
    /// Dust, smoke and haze. Dry deposition: no water, just dirt settling.
    case dust

    /// Does it arrive with enough momentum to throw spray?
    var impacts: Bool {
        switch self {
        case .rain, .hail, .sleet, .freezingRain: return true
        default: return false
        }
    }

    /// Does it leave liquid water that can run?
    var runs: Bool { self == .rain || self == .freezingRain }
}

/// What has collected on one piece of desktop furniture.
///
/// One value per surface rather than per KIND, so two widgets each keep their
/// own state — a widget under the top of the screen catches more than one
/// tucked behind the dock, and averaging them would lose that.
struct SurfaceFilm {
    /// Liquid film on the upward-facing edge, 0..1.
    var wet: Float = 0
    /// Water gathered along the lip: the fat meniscus that beads and runs.
    var lip: Float = 0
    /// Snow lying, in cells.
    var snow: Float = 0
    /// Clear ice, 0..1.
    var glaze: Float = 0
    /// Crystalline bloom, 0..1.
    var frost: Float = 0
    /// Dry deposition, 0..1. Builds over days and washes off in one shower.
    var grime: Float = 0
    /// Condensation out of the air, 0..1.
    var steam: Float = 0
    /// Recent impacts. Decays in a fraction of a second, so it reads as a
    /// flicker of strikes rather than a level.
    var impact: Float = 0
    /// Water that has to go somewhere. Drives the drips off the underside.
    var runoff: Float = 0

    /// Everything wet added up — what the shader needs for one band.
    var anyWater: Float { max(max(wet, lip), max(glaze, steam)) }
}

// MARK: - Simulation

/// Owns every piece of scene state that cannot be derived from the clock.
/// Deliberately allocation-free per frame: the wallpaper runs for weeks.
final class SceneSimulation {

    // grid
    private(set) var cols = 0
    private(set) var rows = 0
    private var SP: Float = 12
    private var W: Float = 0
    private var H: Float = 0

    // weather-driven fields
    private(set) var edgeArr: [Float] = []

    // streaks, packed per column for the shader's colIndex lookup
    private var streaks: [(c: Float, y: Float, len: Float, v: Float, slope: Float)] = []

    /// Rain rasterised into the cell grid, so a streak can lean with the wind
    /// instead of being locked to one column. Bucketing streaks per column made
    /// them fall dead vertical no matter how hard it was blowing — which is what
    /// made the rain look magnetised to the ground.
    private(set) var streakCells: [Float] = []

    /// The same rain at `streakSub`x resolution in each axis.
    ///
    /// A rain streak is a few millimetres wide and a cell is eighteen pixels,
    /// so rasterising at cell resolution fattens every streak to a full square
    /// — the rain reads as falling bricks. This is the same rasterisation run
    /// finer, so the presentation pass can break a cell down and show where
    /// inside it the water actually is.
    ///
    /// The coarse grid is derived from this one rather than rasterised twice,
    /// and it stays the authority on WHICH cells are rain at all: the coarse
    /// pass owns the shape, the detail pass only refines within it. Same rule
    /// as the moon.
    private(set) var streakFine: [Float] = []
    static let streakSub = 3

    /// Counts for diagnostics. Cheap, and the alternative is guessing.
    var debugCounts: String {
        let lit = streakCells.filter { $0 > 0.01 }.count
        let wet = trailCells.filter { $0 > 0.15 }.count
        let mean = trailCells.isEmpty ? 0 : trailCells.reduce(0, +) / Float(trailCells.count)
        let peak = trailCells.max() ?? 0
        return String(format: "T=%.0f RH=%.0f Td=%.1f wind=%.0f uv=%.1f evap=%.3f vpd=%.2f | surfaces=%d splashes=%d streaks=%d lit=%d drops=%d | film mean=%.3f peak=%.2f wet>0.15=%d/%d "
                            + "| pool=%.2f spots=%d grid=%dx%d",
                      lastWeather.temperature, lastWeather.humidity, lastWeather.dewPoint,
                      lastWeather.wind, lastWeather.uv,
                      lastWeather.evaporationRate, lastWeather.vapourPressureDeficit,
                      surfaces.count, splashCount, streaks.count, lit, drops.count, mean, peak, wet, trailCells.count,
                      poolDepth, spots.count, cols, rows)
    }

    /// Wet tracks left behind by running drops.
    ///
    /// A drop running down glass does not travel through dry air — it drags a
    /// film behind it, and that film persists long after the drop has gone.
    /// This is that film, per cell, decaying slowly. It is also unstable: a
    /// long thin rivulet breaks up into beads (Rayleigh-Plateau), which is why
    /// a windscreen ends up covered in little stationary drops along the paths
    /// bigger ones took.
    private var trailCells: [Float] = []

    /// Whether the streak grid currently holds anything. Lets the dry path
    /// clear it exactly once instead of zeroing 2,000 cells every frame.
    private var streakGridLive = false
    private(set) var gpuStreaks: [GPUStreak] = []
    private(set) var colIndex: [SIMD2<Int32>] = []

    // lightning
    private(set) var boltPoints: [GPUBoltPt] = []
    private var boltT0: Float = -9
    private var boltEnergy: Float = 0
    /// Last weather seen, so helpers do not need it threaded through.
    private var lastWeather = WeatherState()
    private var boltActive = false
    private var flashT: Float = -9
    private var nextBolt: Float = 0

    // shooting star
    private var shootT: Float = 1e9
    private(set) var shootActive = false
    private(set) var shootX: Float = 0
    private(set) var shootY: Float = 0
    private(set) var shootT0: Float = 0

    // light pockets
    private(set) var breathers: [GPUBreather] = []

    // glass layer
    private var drops: [GlassDrop] = []
    private var spots: [GlassSpot] = []
    private var vortices: [GlassVortex] = []
    private(set) var glassWet: Float = 0
    /// How hard it is raining right now, 0..1. Drives how strongly water marks
    /// the pane, so the effect tracks the forecast rather than being constant.
    private(set) var rainIntensity: Float = 0

    /// Things on screen for water to land on. Set by the host; empty means the
    /// pane is unobstructed.
    ///
    /// The film state is parallel to this array, so replacing the furniture —
    /// a display change, the dock moving edge — starts the new pieces dry
    /// rather than inheriting the old ones' weather.
    var surfaces: [Surface] = [] {
        didSet {
            guard films.count != surfaces.count else { return }
            films = [SurfaceFilm](repeating: SurfaceFilm(), count: surfaces.count)
        }
    }

    /// What has collected on each surface. Parallel to `surfaces`.
    private(set) var films: [SurfaceFilm] = []

    /// What the sky is currently delivering, in the form a surface feels it.
    private(set) var form: DepositForm = .none
    /// A thunderstorm's outflow: a squall of wind-driven spray at a steep
    /// angle, quite unlike the same rainfall falling straight down.
    private(set) var gustFront = false

    /// Grime settles out of dirty air onto every surface and washes off in
    /// rain, so a filthy week visibly builds up and one shower clears it.
    /// Snow lying on each kind of surface, in cells, keyed by Surface.Kind.
    ///
    /// Declared here because the reference existed without it — an agent was
    /// cut off mid-edit and left the read site behind. Empty means the guard at
    /// the read site never passes, so snow caps are inert rather than wrong:
    /// restoring the build without inventing accumulation physics that was
    /// never written and cannot be verified.
    private var snowCap: [Int32: Float] = [:]

    private(set) var grime: Float = 0
    /// Condensation on the furniture: warm wet air against a cool surface.
    private(set) var steam: Float = 0

    /// How long it has been raining without a meaningful break, in seconds.
    /// Long rain pools water along the bottom edge — a flood watch should look
    /// like one.
    private(set) var rainDuration: Float = 0
    /// Depth of standing water at the bottom edge, in cells.
    private(set) var poolDepth: Float = 0

    /// How deep the pool is allowed to get.
    ///
    /// Anything standing at the bottom of the screen — the dock, usually —
    /// occupies that space, so water cannot pile up in front of it. Without
    /// this the pool grew straight past the dock's top edge and swallowed every
    /// drop before it could land on it, which is why no splash ever appeared.
    private var maxPoolDepth: Float {
        let floorRow = Float(rows)
        var limit = floorRow * 0.22
        for s in surfaces where s.top > floorRow * 0.5 * SP {
            limit = min(limit, max(0.6, (floorRow * SP - s.top) / SP * 0.7))
        }
        return limit
    }
    private(set) var glassQuads: [GlassQuad] = []

    /// Per-cell glass lookup, cols*rows. Lets the presentation pass ask "is
    /// there water on this cell?" in one texture fetch instead of walking a
    /// particle list per pixel.
    ///   x = radius in pixels   y = kind (0 none, 1 drop, 2 trail, 3 spot, 4 vortex)
    ///   z,w = the element's centre within the cell, 0..1
    private(set) var glassCells: [SIMD4<Float>] = []

    private var rng = SystemRandomNumberGenerator()
    private func rnd() -> Float { Float.random(in: 0..<1, using: &rng) }

    // MARK: Grid

    /// Rebuild the grid. Called on resize only — never per frame, and never as
    /// part of waking from an idle.
    ///
    /// The height is fitted EXACTLY, and the cell size is allowed to be
    /// fractional to do it. Snapping the cell to a whole pixel is what leaves a
    /// remainder in the first place, and a remainder is a strip of display the
    /// grid never reaches — a sliver of a row hanging off the bottom edge.
    /// Choosing the row count first and dividing gives whole cells from the top
    /// edge to the bottom edge with nothing left over.
    ///
    /// This is not stretching: `sp` is still one number used for both axes, so
    /// the cells stay square. It is only the pitch that stops being an integer.
    func resize(pixelWidth: Float, pixelHeight: Float, gridRows: Int) {
        var sp = max(6, (pixelHeight / Float(gridRows)).rounded())
        let r = max(1, Int((pixelHeight / sp).rounded()))
        sp = pixelHeight / Float(r)
        rows = max(1, Int((pixelHeight / sp).rounded()))
        cols = max(1, Int((pixelWidth / sp).rounded()))
        SP = sp
        H = Float(rows) * sp
        W = Float(cols) * sp
        edgeArr = [Float](repeating: 0, count: cols)
        streakCells = [Float](repeating: 0, count: cols * rows)
        streakFine  = [Float](repeating: 0,
                              count: cols * rows * SceneSimulation.streakSub * SceneSimulation.streakSub)
        trailCells = [Float](repeating: 0, count: cols * rows)
        colIndex = [SIMD2<Int32>](repeating: .zero, count: cols)
        glassCells = [SIMD4<Float>](repeating: .zero, count: cols * rows)

        // three drifting light pockets (roomstand.py:2028)
        breathers = (0..<3).map { _ in
            GPUBreather(ax: rnd() * W, ay: rnd() * H,
                        R: H * (0.22 + 0.18 * rnd()),
                        per: 16 + rnd() * 24,
                        s1: 0.018 + rnd() * 0.022,
                        s2: 0.014 + rnd() * 0.020,
                        ph: rnd() * 6.28, ph2: rnd() * 6.28)
        }
        seed(now: 0)
    }

    var cellSize: Float { SP }
    var pixelWidth: Float { W }
    var pixelHeight: Float { H }

    /// Called when the scene jumps somewhere else. Anything in flight belongs
    /// to the old sky and must go; anything resting on the glass belongs to the
    /// pane and stays, because the pane is your screen rather than the weather.
    func locationChanged(now sec: Float) {
        streaks.removeAll(keepingCapacity: true)
        rasteriseStreaks()
        streakGridLive = false
        boltActive = false
        boltPoints.removeAll(keepingCapacity: true)
        // Spray is mid-air; clinging and running drops are not.
        drops.removeAll { $0.splashLife > 0 }
        shootActive = false
        nextBolt = sec + 4 + rnd() * 8
    }

    /// Reset the transient weather effects (roomstand.py:2063).
    func seed(now sec: Float) {
        streaks.removeAll(keepingCapacity: true)
        boltActive = false
        flashT = -9
        nextBolt = sec + 9 + rnd() * 14
        shootT = sec + 60 + rnd() * 180
        shootActive = false
    }

    // MARK: Stepping

    /// Advance by `dt` seconds at absolute time `sec`.
    func step(dt rawDT: Float, sec: Float, state: SceneState) {
        let dt = min(0.1, max(0, rawDT))
        let w = state.weather
        lastWeather = w
        let covF = state.covF
        let sAlt = state.astro.sunAlt

        // The hanging deck is the LOW layer. Driving it from total cover made
        // a sky of pure high cirrus grow a dense lid it should not have.
        let deckCover = max(w.cloudLow / 100, covF * 0.25)
        updateCloudEdge(sec: sec, covF: deckCover, wind: w.wind)
        updateStreaks(dt: dt, kind: w.effectiveKind, covF: covF, weather: w, facingAz: state.facingAz)
        updateLightning(dt: dt, sec: sec, kind: w.effectiveKind)
        updateShootingStar(sec: sec, sunAlt: sAlt, kind: w.effectiveKind)
        updateGlass(dt: dt, state: state)
    }

    /// Catch up after the renderer has been idle. The scene's analytic terms
    /// need nothing — they read absolute time — but the integrators would
    /// otherwise resume frozen mid-fall. Bounded so a week of sleep costs the
    /// same as a second.
    func fastForward(to sec: Float, elapsed: Float, state: SceneState) {
        guard elapsed > 0.5 else { return }
        let steps = min(180, Int(elapsed / 0.016))       // at most ~3s of catch-up
        let dt: Float = 0.016
        var t = sec - Float(steps) * dt
        for _ in 0..<steps {
            t += dt
            step(dt: dt, sec: t, state: state)
        }
    }

    // MARK: Cloud edge

    /// Per-column cloud deck height in pixels (roomstand.py:2280).
    private func updateCloudEdge(sec: Float, covF: Float, wind: Float) {
        let depth = H * (0.10 + 0.38 * covF)
        let spd = 0.003 + min(0.02, wind * 0.0004)
        for c in 0..<cols {
            let cx = Float(c) * SP
            let n = 0.5
                  + 0.28 * sin(cx * 0.012 + sec * spd)
                  + 0.18 * sin(cx * 0.027 - sec * spd * 1.4 + 2.1)
                  + 0.12 * sin(cx * 0.051 + sec * spd * 0.7 + 4.0)
            let prof = n + (covF - 0.55) * 1.6
            // Soft knee instead of min(1, prof). A hard clamp meant that under
            // heavy cover the profile spent long stretches pinned at exactly 1,
            // so the deck's edge came out as flat-topped rectangles with cliffs
            // where it came off the clamp — blocks, not cloud. This approaches
            // 1 asymptotically, so the shape stays wavy all the way up.
            let knee: Float = 0.62
            let p = prof <= knee ? prof
                  : 1 - (1 - knee) * expf(-(prof - knee) / (1 - knee))
            edgeArr[c] = prof <= 0 ? 0 : depth * (0.25 + 0.75 * p)
        }
    }

    // MARK: Rain and snow

    private func updateStreaks(dt: Float, kind: SceneKind, covF: Float,
                               weather: WeatherState, facingAz: Float) {
        // Nothing measured means nothing falls, whatever the code claims.
        guard kind.isWet, weather.isPrecipitating else {
            // Clear the rasterised grid too, not just the list. Without this the
            // last frame of rain stays in the texture indefinitely — switch from
            // a wet city to a dry one and the falling rain freezes mid-air and
            // never leaves. Water already ON the glass is deliberately kept:
            // the pane stays wet where it got wet, wherever you are now looking.
            if !streaks.isEmpty || streakGridLive {
                streaks.removeAll(keepingCapacity: true)
                rasteriseStreaks()            // zeroes the grid on its way in
                streakGridLive = false
            }
            return
        }
        streakGridLive = true
        let intensity: Float
        switch kind {
        case .snow:    intensity = min(1, weather.snow / 4)
        case .thunder: intensity = min(1, 0.5 + weather.rain / 8)
        default:       intensity = min(1, weather.rain / 6)
        }
        let rate = max(0.08, min(0.95, intensity * 0.9 + covF * 0.15))
        let maxStreaks = Int((30 + intensity * 90).rounded())
        let baseSpeed = kind == .snow ? (0.15 + intensity * 0.25)
                                      : (0.6 + intensity * 1.2 + weather.wind * 0.02)

        // spawn rate is per-frame in the reference; scale by dt so the look
        // holds at any refresh rate
        if rnd() < rate * dt * 60 && streaks.count < maxStreaks {
            for _ in 0..<6 {
                let c = Int(rnd() * Float(cols))
                if c < cols && edgeArr[c] > 0 {
                    // wind direction relative to facing: eastward drifts right
                    let relWind = ((weather.windDir - facingAz + 180 + 360)
                                    .truncatingRemainder(dividingBy: 360)) - 180
                    let driftSign: Float = weather.wind > 8
                        ? (relWind > 0 ? 1 : -1) * min(1, abs(relWind) / 90) : 0
                    let len: Float = kind == .snow ? (2 + rnd() * 2)
                                                   : (3 + intensity * 5 + rnd() * 3)
                    // Slope is horizontal cells per vertical cell: the ratio of
                    // the wind's push to the drop's fall speed. Fast rain in
                    // light wind is near vertical; slow snow in a gale goes
                    // almost sideways, which is exactly how it behaves.
                    let fall = max(baseSpeed, 0.05)
                    let push = driftSign * (weather.wind / 22)
                    streaks.append((c: Float(c), y: edgeArr[c] / SP, len: len,
                                    v: baseSpeed * (0.7 + rnd() * 0.6),
                                    slope: max(-2.5, min(2.5, push / fall))))
                    break
                }
            }
        }
        let f = dt * 60           // reference integrates per frame at 60fps
        var i = streaks.count - 1
        while i >= 0 {
            let dy = streaks[i].v * f
            streaks[i].y += dy
            // The head travels along the slope, so the whole streak leans.
            streaks[i].c += streaks[i].slope * dy
            if streaks[i].y - streaks[i].len > Float(rows)
                || streaks[i].c < -4 || streaks[i].c > Float(cols) + 4 {
                streaks.remove(at: i)
            }
            i -= 1
        }
        rasteriseStreaks()
    }

    /// Draw each streak into the cell grid along its slope. Walking the streak
    /// backwards from its head means the tail trails the way it actually fell,
    /// so a gust bends the whole trail rather than shearing it.
    private func rasteriseStreaks() {
        guard !streakCells.isEmpty else { return }
        let N = SceneSimulation.streakSub
        let fw = cols * N, fh = rows * N
        let fn = Float(N)
        for i in 0..<streakFine.count { streakFine[i] = 0 }

        // Walk each streak in sub-cell steps rather than cell steps, and place
        // it in the sub-cell it actually passes through. Half a sub-cell per
        // step, so a step can never skip one.
        for s in streaks {
            var k: Float = 0
            let step = 0.5 / fn
            while k < s.len {
                let row = (s.y - k) * fn
                let col = (s.c - s.slope * k) * fn + (fn - 1) * 0.5
                k += step
                let fy = Int(row), fx = Int(col.rounded())
                guard fy >= 0, fy < fh, fx >= 0, fx < fw else { continue }
                let idx = fy * fw + fx
                let v = 1 - k / s.len                    // brightest at the head
                if v > streakFine[idx] { streakFine[idx] = v }
            }
        }

        // Reduce to the coarse grid. Max, not mean: a cell a streak passes
        // through IS a rain cell, and the coarse pass has to say so at full
        // strength or the detail pass has nothing to refine within.
        for cy in 0..<rows {
            for cx in 0..<cols {
                var m: Float = 0
                for j in 0..<N {
                    let base = (cy * N + j) * fw + cx * N
                    for i in 0..<N { m = max(m, streakFine[base + i]) }
                }
                streakCells[cy * cols + cx] = m
            }
        }
    }

    // Streaks are rasterised into `streakCells` rather than bucketed per
    // column — see rasteriseStreaks. The old per-column index could only
    // express a vertical fall.

    // MARK: Lightning

    private func updateLightning(dt: Float, sec: Float, kind: SceneKind) {
        let w = lastWeather
        let energy = w.convectiveEnergy
        guard energy > 0.02 else {
            if boltActive { boltActive = false; boltPoints.removeAll(keepingCapacity: true) }
            return
        }
        if sec > nextBolt && !boltActive {
            for _ in 0..<8 {
                let c = Int(rnd() * Float(cols))
                if c < cols && edgeArr[c] > 0 {
                    boltPoints.removeAll(keepingCapacity: true)
                    // Branching, forked descent. A real channel steps downward
                    // and forks; a straight line reads as a laser.
                    var bx = Float(c) * SP, by = edgeArr[c] * 0.5
                    var drift = (rnd() - 0.5) * SP * 0.8
                    while by < H * 0.96 && boltPoints.count < 100 {
                        boltPoints.append(GPUBoltPt(x: bx, y: by))
                        by += SP * (1.1 + rnd() * 0.9)
                        drift += (rnd() - 0.5) * SP * 1.1
                        drift *= 0.72                       // channels tend back to vertical
                        bx += drift
                        // Occasional fork, stronger in a more energetic storm.
                        if rnd() < 0.10 * energy && boltPoints.count < 80 {
                            var fx = bx, fy = by
                            let fd = (rnd() - 0.5) * SP * 3
                            for _ in 0..<Int(3 + rnd() * 4) {
                                fx += fd * 0.5; fy += SP * 1.3
                                if fy > H { break }
                                boltPoints.append(GPUBoltPt(x: fx, y: fy))
                            }
                        }
                    }
                    boltActive = true
                    boltT0 = sec
                    boltEnergy = energy
                    break
                }
            }
            if !boltActive { nextBolt = sec + 6 }
        }
        if boltActive && sec - boltT0 > 0.18 + rnd() * 0.12 {
            flashT = sec
            boltActive = false
            boltPoints.removeAll(keepingCapacity: true)
            nextBolt = sec + strikeInterval(energy: energy, weather: w)
        }
    }

    /// Seconds until the next strike.
    ///
    /// Flash rate scales steeply with CAPE — an energetic cell can flash every
    /// few seconds while a marginal one goes minutes between strikes, so a fixed
    /// 16-40s window is wrong at both ends. Rainfall matters too: the electrical
    /// activity and the downpour peak together.
    private func strikeInterval(energy: Float, weather w: WeatherState) -> Float {
        let wet = min(1, w.effectiveRain / 4)
        let rate = energy * energy * (0.55 + wet * 0.45)     // strikes per second, roughly
        let mean = max(2.5, 1 / max(rate * 0.22, 0.004))
        // Poisson-ish spacing: strikes cluster rather than metronome.
        let u = max(0.02, rnd())
        return min(300, mean * -log(u))
    }

    /// Decaying, oscillating flash after the bolt (roomstand.py:2325).
    func flashAmp(sec: Float, kind: SceneKind) -> Float {
        guard kind == .thunder || flashT > 0 else { return 0 }
        let ft = sec - flashT
        guard ft >= 0 && ft < 0.7 else { return 0 }
        // Brighter, longer afterglow from a more energetic strike, and a
        // couple of flickers as the channel re-illuminates.
        let fe = exp(-ft * (5.5 - boltEnergy * 1.6))
        let flicker = 0.55 + 0.45 * sin(ft * (46 + boltEnergy * 20))
        return max(0, fe * flicker * (0.6 + boltEnergy * 0.6))
    }

    // MARK: Shooting star

    private func updateShootingStar(sec: Float, sunAlt: Float, kind: SceneKind) {
        guard sunAlt < -4, kind == .sun || kind == .partly else { return }
        if sec > shootT && !shootActive {
            shootActive = true
            shootX = W * (0.1 + 0.5 * rnd())
            shootY = H * (0.06 + 0.18 * rnd())
            shootT0 = sec
            shootT = sec + 120 + rnd() * 240
        }
        if shootActive && sec - shootT0 > 0.8 { shootActive = false }
    }

    /// Break a landing drop into spray. Momentum is shared out sideways and
    /// upward, so the spray arcs the way water actually does rather than
    /// puffing symmetrically, and the impact wets the edge it hit.
    ///
    /// A hailstone or an ice pellet does the opposite of a raindrop: almost all
    /// of its momentum comes back off the surface and almost none of its mass
    /// stays, so it bounces high and leaves the lip nearly dry. That difference
    /// is the whole of what makes hail read as hail.
    private func splash(at d: GlassDrop, on i: Int) {
        splashCount += 1
        let s = surfaces[i]
        let impact = min(1, d.v / 260) * min(1, d.r / (SP * 0.5))
        films[i].impact = min(1, films[i].impact + impact * (form == .hail ? 1.4 : 0.7))
        guard impact > 0.05 else {
            films[i].lip = min(1, films[i].lip + 0.04)
            return
        }
        // Bounce fraction: liquid stays, ice comes back.
        let bounce: Float = form == .hail ? 0.85 : (form == .sleet ? 0.7 : 0.35)
        let n = min(7, 1 + Int(impact * (form == .hail ? 6 : 4)))
        for _ in 0..<n {
            let sideways = (rnd() * 2 - 1) * d.v * (0.45 + bounce * 0.5)
            let upward = -d.v * (0.20 + bounce * 0.45 + rnd() * 0.30)
            drops.append(GlassDrop(x: d.x + sideways * 0.01,
                                   y: s.top - SP * 0.15,
                                   r: d.r * (0.30 + rnd() * 0.25),
                                   v: upward,
                                   rCrit: d.rCrit,
                                   falling: true,
                                   vx: sideways,
                                   splashLife: 0.30 + rnd() * 0.40))
        }
        films[i].lip = min(1, films[i].lip + impact * 0.30 * (1 - bounce))
        films[i].wet = min(1, films[i].wet + impact * 0.18 * (1 - bounce))
        films[i].runoff = min(1, films[i].runoff + impact * 0.20 * (1 - bounce))
    }

    /// Splash events since start — purely for verifying the collision path.
    private(set) var splashCount = 0

    // MARK: Weather on the furniture
    //
    // The reason the dock and the widgets used to look untouched was not that
    // the physics was wrong: it was that NOTHING READ IT. Wetness accumulated
    // into a dictionary no pass ever sampled, and it could only accumulate at
    // all if a randomly seeded pane droplet happened to fall on the right
    // column. So it is driven from the WEATHER here — the sky is raining on the
    // whole surface, not on the one column a particle chose — and splashes only
    // add a kick on top.

    /// Classify what is falling into the form a surface actually feels.
    private func precipitationForm(_ w: WeatherState) -> DepositForm {
        let code = w.code
        let t = w.temperature
        if w.isPrecipitating {
            if code == 96 || code == 99 { return .hail }
            // The freezing-drizzle and freezing-rain codes are explicit, and
            // they are the one case the temperature alone cannot tell you: the
            // drop is liquid all the way down and only freezes on contact.
            if code == 56 || code == 57 || code == 66 || code == 67 { return .freezingRain }
            if w.snow >= 0.05 || (code >= 71 && code <= 77) || code == 85 || code == 86 {
                // Wet snow above freezing arrives as slush and behaves like
                // sleet on a surface: patchy, and gone in minutes.
                return (t > 1.5 && w.frozenFraction < 0.85) ? .sleet : .snow
            }
            if t <= 0.3 { return .freezingRain }
            if w.frozenFraction > 0.25 { return .sleet }
            // Drizzle is a DROP SIZE, not a rate. The codes say so directly;
            // failing that, a trace falling out of a low deck in light wind is
            // the same thing.
            if code >= 51 && code <= 55 { return .drizzle }
            if w.precipAmount < 0.35 && w.wind < 22 { return .drizzle }
            return .rain
        }
        // Nothing falling. What the air alone does to a surface.
        if t < 0.5 && w.humidity > 78 { return .frost }
        if w.isFoggy || w.fogginess > 0.55 { return .fog }
        if w.aqi > 85 || w.smoke > 0.22 || (w.visibility < 6000 && w.humidity < 70) { return .dust }
        return .none
    }

    /// Advance what is sitting on each piece of furniture.
    ///
    /// Every branch is a real behaviour of that hydrometeor against a real
    /// surface, not a restyling of the same wetness: snow accumulates and
    /// melts from the margins, freezing rain glazes and does not run, ice
    /// pellets bounce off and leave almost nothing, fog wets the undersides
    /// too, frost blooms out of the vapour, and dust just settles.
    private func updateSurfaces(dt: Float, w: WeatherState) {
        guard films.count == surfaces.count, !films.isEmpty else { return }
        let strength = Furniture.options.furniture
        guard strength > 0.001 else {
            for i in 0..<films.count { films[i] = SurfaceFilm() }
            grime = 0; steam = 0
            return
        }
        let evap = w.evaporationRate
        let t = w.temperature
        let rate = min(1.4, w.precipAmount / 3)          // arrival rate, 0..~1.4
        // Wind drives water onto and off a lip; a gust front throws it sideways.
        let windF = min(1.5, w.wind / 30)
        // Dirty air, from the two measures that actually track deposition.
        let dirty = min(1, max(w.aqi - 40, 0) / 220 + w.smoke * 0.6 + max(0, 1 - w.visibility / 9000) * 0.3)
        // How close the air is to dumping its water out onto a cold surface.
        let condense = min(1, max(0, 1 - w.dewSpread / 2.5)) * min(1, 0.35 + w.fogginess)

        var meanGrime: Float = 0, meanSteam: Float = 0
        for i in 0..<films.count {
            var f = films[i]

            // ---- what arrives
            switch form {
            case .rain:
                f.wet = min(1, f.wet + dt * (0.35 + rate * 0.9))
                f.lip = min(1, f.lip + dt * (0.22 + rate * 0.8) * (0.6 + windF * 0.5))
                f.runoff = min(1, f.runoff + dt * (0.20 + rate * 0.7))
                f.grime = max(0, f.grime - dt * (0.10 + rate * 0.35))
            case .drizzle:
                // Too fine to run: it wets evenly and stops. The lip never
                // builds a meniscus, which is why drizzle looks matte.
                f.wet = min(0.72, f.wet + dt * 0.16)
                f.lip = max(f.lip * (1 - dt * 0.3), min(0.10, f.lip))
                f.runoff = min(0.25, f.runoff + dt * 0.03)
                f.grime = max(0, f.grime - dt * 0.05)
            case .freezingRain:
                // Liquid on arrival, ice within seconds. The glaze thickens
                // steadily and does not run — that is what makes it dangerous
                // and what makes it look like varnish rather than like rain.
                f.wet = min(0.55, f.wet + dt * 0.25)
                f.glaze = min(1, f.glaze + dt * (0.05 + rate * 0.12))
                f.lip = min(0.35, f.lip + dt * 0.08)
            case .sleet:
                // Bounces. Almost nothing stays, and what does is patchy.
                f.impact = min(1, f.impact + dt * (0.6 + rate * 1.4))
                f.wet = min(0.45, f.wet + dt * 0.12)
                f.snow = min(0.9, f.snow + dt * rate * 0.06)
                f.lip = min(0.2, f.lip + dt * 0.03)
            case .snow:
                // Accumulates on the upward-facing edge. Rate is the snowfall
                // itself; the cap is how deep a lip a few centimetres wide can
                // actually hold before it sloughs off.
                f.snow = min(3.2, f.snow + dt * (0.02 + w.snow * 0.05))
                f.wet = max(0, f.wet - dt * 0.05)
                f.grime = max(0, f.grime - dt * 0.04)
            case .hail:
                f.impact = min(1, f.impact + dt * (1.2 + rate * 2.0))
                f.wet = min(1, f.wet + dt * (0.25 + rate * 0.5))
                f.lip = min(0.6, f.lip + dt * 0.2)
                f.runoff = min(1, f.runoff + dt * 0.3)
                f.grime = max(0, f.grime - dt * 0.3)
            case .fog:
                // No impact at all: the water arrives out of the air, so it
                // wets every face evenly and beads only once the film is
                // thick enough to run.
                f.steam = min(1, f.steam + dt * (0.02 + condense * 0.10))
                f.wet = min(0.6, f.wet + dt * condense * 0.05)
                if f.steam > 0.75 { f.lip = min(0.45, f.lip + dt * 0.05) }
            case .frost:
                // Deposition straight from vapour. Needs a sub-zero surface and
                // air with something in it; it grows fastest on a clear night,
                // which is when the surface radiates coldest.
                let cold = min(1, max(0, (0.5 - t) / 6))
                let clear = 1 - min(1, w.cover / 100) * 0.6
                f.frost = min(1, f.frost + dt * 0.035 * cold * clear * min(1, w.humidity / 80))
                f.steam = min(0.5, f.steam + dt * condense * 0.04)
            case .dust:
                f.grime = min(1, f.grime + dt * dirty * 0.012)
            case .none:
                break
            }

            // Dirt settles whatever else is going on; rain is what removes it.
            if form != .rain && form != .hail {
                f.grime = min(1, f.grime + dt * dirty * 0.004)
            }

            // ---- what leaves
            //
            // Liquid goes by evaporation, on the same physical rate as the
            // pane, so the dock dries when the pane dries instead of on its own
            // invented timer.
            let dry = dt * (0.004 + evap * 0.09)
            if form != .rain && form != .drizzle && form != .hail {
                f.wet = max(0, f.wet - dry)
                f.lip = max(0, f.lip - dry * 1.6)
                f.runoff = max(0, f.runoff - dt * 0.25)
            } else {
                f.runoff = max(0, f.runoff - dt * 0.12)
            }
            if form != .fog { f.steam = max(0, f.steam - dt * (0.01 + evap * 0.12)) }

            // Snow: melt is driven by the surface being above freezing, and it
            // eats the margins first, which is why a snow cap narrows before it
            // thins. Sublimation is much slower and happens even below zero.
            if f.snow > 0 && form != .snow {
                let melt = max(0, t) * 0.008 + max(0, w.uv - 1) * 0.0015
                let sublime = 0.0008 * (0.3 + evap)
                f.snow = max(0, f.snow - dt * (melt + sublime))
                // What melts becomes water on the lip.
                if melt > 0 { f.wet = min(1, f.wet + dt * melt * 1.6) }
            }
            // Ice: only above zero, and slowly — a glaze survives a long thaw.
            if f.glaze > 0 && form != .freezingRain {
                let thaw = max(0, t) * 0.006 + max(0, w.uv - 2) * 0.001
                f.glaze = max(0, f.glaze - dt * (thaw + 0.0004))
                if thaw > 0 { f.wet = min(1, f.wet + dt * thaw * 1.2) }
            }
            // Frost sublimates fast in sun and vanishes the moment it thaws.
            if f.frost > 0 && form != .frost {
                let gone = max(0, t + 0.5) * 0.02 + max(0, w.uv) * 0.004 + 0.0006
                f.frost = max(0, f.frost - dt * gone)
            }
            f.impact = max(0, f.impact - dt * 3.2)

            films[i] = f
            meanGrime += f.grime
            meanSteam += max(f.steam, f.wet * 0.3)
        }

        let n = Float(films.count)
        // The whole-pane terms follow the furniture rather than being invented
        // separately: they are the same air doing the same thing.
        grime = min(1, meanGrime / n)
        steam = min(1, meanSteam / n)
    }

    /// Drips off the underside of anything with pane below it.
    ///
    /// A widget or the menu bar is an eave: water that runs over its top edge
    /// hangs off the bottom lip, grows until surface tension gives out, and
    /// falls. It is the single most legible sign that a thing on screen is wet,
    /// because the drip is in clear space rather than behind the furniture.
    private func shedDrips(dt: Float) {
        guard films.count == surfaces.count, drops.count < Self.maxDrops else { return }
        for i in 0..<surfaces.count {
            let s = surfaces[i]
            guard s.hasUnderside(screenHeight: H) else { continue }
            let f = films[i]
            let supply = f.runoff * 0.8 + f.lip * 0.4 + f.steam * 0.15
            guard supply > 0.06, rnd() < supply * dt * 3.5 else { continue }
            let r0 = SP * (0.30 + rnd() * 0.35)
            drops.append(GlassDrop(x: s.left + rnd() * s.w,
                                   y: s.bottom + r0,
                                   r: r0,
                                   v: 12,
                                   rCrit: SP * (0.55 + rnd() * 0.45),
                                   falling: true))
            films[i].runoff = max(0, films[i].runoff - 0.05)
        }
    }

    // MARK: Glass layer
    //
    // Treats the screen as a pane you are looking through, so weather leaves a
    // trace instead of only falling past it: droplets cling, swell and run;
    // the pane dries slowly afterwards, faster under sun; what evaporates
    // leaves mineral spots that stay until the next rain washes them off; hard
    // wind spins up visible vortices. Snapped to the dot grid, never smooth.

    /// Age the film by real evaporation rather than a constant.
    ///
    /// A thin film also drains and beads faster than a thick one, so decay is
    /// slightly superlinear — which is why tracks fade from their edges inward
    /// instead of uniformly.
    private func ageTrails(dt: Float, evaporation: Float) {
        guard !trailCells.isEmpty else { return }
        // Real timescales. Water on glass takes tens of minutes to clear in
        // humid still air and a minute or two when it is dry, windy and sunny;
        // the earlier constants cleared everything in seconds regardless, which
        // made the whole evaporation model invisible.
        //
        //   evaporation ~1.0  (30C, 25% RH, 25km/h, UV 8)  -> ~1 minute
        //   evaporation ~0.07 (30C, 92% RH, calm, no sun)  -> ~12 minutes
        //   while raining (pinned near 0)                  -> effectively never
        let base = dt * (0.0003 + evaporation * 0.010)
        for i in 0..<trailCells.count where trailCells[i] > 0 {
            let thin = 1 + (1 - trailCells[i]) * 0.8
            trailCells[i] = max(0, trailCells[i] - base * thin)
        }
    }

    /// Rayleigh-Plateau: a thin column of liquid is unstable and pinches into
    /// beads. On glass this is why a track left by a running drop slowly turns
    /// into a line of little stationary ones.
    private func breakUpTrails(dt: Float, wet: Bool) {
        // A drying film thins and retreats rather than beading up; pinch-off
        // only happens while there is still water arriving.
        guard wet, drops.count < 110, !trailCells.isEmpty else { return }
        let attempts = 3
        for _ in 0..<attempts {
            guard rnd() < dt * 9 else { continue }
            let i = Int(rnd() * Float(trailCells.count))
            guard i < trailCells.count, trailCells[i] > 0.45 else { continue }
            let cx = i % cols, cy = i / cols
            let r0 = SP * (0.10 + rnd() * 0.10) * trailCells[i]
            guard r0 > SP * 0.05 else { continue }
            drops.append(GlassDrop(
                x: (Float(cx) + 0.5) * SP + (rnd() - 0.5) * SP * 0.4,
                y: (Float(cy) + 0.5) * SP,
                r: r0,
                v: 0,
                rCrit: SP * (0.34 + rnd() * 0.30),
                falling: false))
            // The film gives up what the bead took.
            trailCells[i] = max(0, trailCells[i] - 0.5)
        }
    }

    /// Ceiling on the droplet population.
    ///
    /// Lower than it was, and deliberately: the beads are now large enough to
    /// read as water rather than as speckle, and ninety large beads is a pane
    /// covered in confetti again. A windscreen in real rain carries a handful
    /// of runs and a scatter of held drops, not a uniform field.
    static let maxDrops = 46

    private func updateGlass(dt rawDT: Float, state: SceneState) {
        glassQuads.removeAll(keepingCapacity: true)
        let dt = min(0.05, rawDT)
        let w = state.weather
        // Measured, not classified. The code alone used to be enough to soak
        // the pane on a dry day.
        let wet = w.isPrecipitating
        form = precipitationForm(w)
        // A thunderstorm's outflow. The gust front arrives before the core and
        // drives the rain in at a steep angle — the same rainfall, thrown
        // sideways, which is a different picture on a vertical pane.
        gustFront = w.isThundering && (w.gustiness > 0.3 || w.gusts > 38)
        let inten: Float = wet ? max(0.12, min(1, 0.12 + w.precipAmount / 4)) : 0
        // Genuine intensity, not the floored spawn rate: 0.1mm drizzle should
        // read as almost nothing, 5mm as a soaking.
        rainIntensity = wet ? min(1, w.precipAmount / 5) : 0

        // Everything on the furniture, and the whole-screen grime and steam
        // terms that follow from it. Runs whatever the pane-water switch says:
        // the two are separate settings because they are separate effects.
        updateSurfaces(dt: dt, w: w)

        // The pane itself can be switched off. Clear what is on it once rather
        // than leaving the last wet frame frozen there forever.
        let paneOn = Furniture.options.paneWater && Furniture.options.pane > 0.001
        if !paneOn {
            if !drops.isEmpty || !spots.isEmpty || !vortices.isEmpty || glassWet > 0 || poolDepth > 0 {
                drops.removeAll(keepingCapacity: true)
                spots.removeAll(keepingCapacity: true)
                vortices.removeAll(keepingCapacity: true)
                for i in 0..<trailCells.count { trailCells[i] = 0 }
                glassWet = 0; poolDepth = 0
            }
            rasteriseGlass()
            return
        }

        // wetness accumulates while raining and evaporates afterwards
        if wet {
            glassWet = min(1, glassWet + dt * (0.09 + inten * 0.22))
        } else {
            // Same evaporation model as the trails, so the pane dries as one
            // thing rather than each layer on its own timer.
            glassWet = max(0, glassWet - dt * (0.002 + w.evaporationRate * 0.06))
        }

        // Age the film and let it pinch into beads. These were defined but
        // never called — the call sites were lost in an earlier edit, which is
        // why water accumulated forever with no decay path at all.
        ageTrails(dt: dt, evaporation: w.evaporationRate)
        breakUpTrails(dt: dt, wet: wet)

        shedDrips(dt: dt)

        // ---- droplets ------------------------------------------------------
        //
        // Seeding. Two numbers matter and they were both wrong for the look:
        // how MANY and how BIG.
        //
        // A drop had to reach 0.34-0.64 of a cell to detach, so a mature bead
        // was under one cell across. A one-cell bead has no shape to shade —
        // the only way it could show anything was to subdivide, and a
        // subdivided single cell is the little dark cross that made the whole
        // effect read as speckle. A bead has to SPAN cells to be made of them.
        //
        // So drops are fewer and roughly twice the size. On a windscreen you
        // see a handful of fat runs and a scatter of held drops, never an even
        // field of identical specks.
        //
        // Drop size is also a property of the WEATHER, not a constant: drizzle
        // is 0.2mm and never beads, a shower is 2mm and runs immediately.
        let sizeF: Float
        switch form {
        case .drizzle:  sizeF = 0.55
        case .fog:      sizeF = 0.70
        case .hail:     sizeF = 1.35
        default:        sizeF = 1.0
        }
        // Drizzle wets everything and beads almost nothing, so it gets many
        // tiny drops that never detach; rain gets few large ones that do.
        let seedRate = (form == .drizzle ? 1.5 : 0.55) * inten
        if wet && drops.count < Self.maxDrops && rnd() < seedRate * dt * 60 {
            let r0 = SP * (0.16 + rnd() * 0.14) * sizeF
            drops.append(GlassDrop(x: rnd() * W, y: rnd() * H * 0.85,
                                   r: r0, v: 0,
                                   // Spread of critical radii stands in for a
                                   // real surface: some spots hold a bigger
                                   // bead than others. Drizzle's drops are held
                                   // far past where a raindrop would let go,
                                   // because they are too light to overcome the
                                   // tension holding them at all.
                                   rCrit: SP * (0.62 + rnd() * 0.55) * sizeF
                                        * (form == .drizzle ? 2.4 : 1),
                                   falling: false))
        }

        // Condensation seeding. Fog and mist put water on the pane with no
        // impact whatsoever — it grows out of the air, evenly, everywhere.
        if form == .fog && drops.count < Self.maxDrops && rnd() < dt * 18 {
            let r0 = SP * (0.10 + rnd() * 0.10)
            drops.append(GlassDrop(x: rnd() * W, y: rnd() * H,
                                   r: r0, v: 0,
                                   rCrit: SP * (0.75 + rnd() * 0.6),
                                   falling: false))
        }

        let gravity: Float = 900              // px/s^2
        // A squall throws the water in at an angle rather than dropping it, so
        // a run down the pane leans hard instead of going straight.
        let windPush = w.wind / 90 * (gustFront ? 3.2 : 1)
        let evaporation = w.evaporationRate
        var i = drops.count - 1
        while i >= 0 {
            var d = drops[i]

            if d.splashLife > 0 {
                // Spray thrown off an impact. Unlike a drop on the glass this
                // is in the air, so it keeps its sideways momentum and arcs
                // under gravity until it lands back on the pane.
                d.splashLife -= dt
                d.v += gravity * dt
                d.y += d.v * dt
                d.x += d.vx * dt
                d.vx *= (1 - dt * 1.6)            // air drag
                d.r = max(d.r * (1 - dt * 0.5), SP * 0.04)
                if d.splashLife <= 0 { d.splashLife = 0; d.falling = true; d.vx = 0 }
            } else if !d.falling {
                // Condensation while it is raining; evaporation when it is not.
                //
                // Previously a clinging drop could only ever grow, so once the
                // rain stopped the pane kept its beads indefinitely and they
                // went on feeding the film — the reason water piled up and
                // never dried. A drop loses volume from its surface, so radius
                // shrinks roughly linearly with the evaporation rate.
                //
                // Fog grows drops with no rain at all: the water arrives out of
                // the air rather than out of the sky, which is why a misty
                // night fogs a window that never gets rained on.
                let feed = max(inten, form == .fog ? 0.5 * min(1, 0.4 + w.fogginess) : 0)
                if feed > 0.01 {
                    // Drizzle's drops are too light to gather: they stall small
                    // and stay as a matte film rather than growing into beads.
                    let cap = form == .drizzle ? SP * 0.42 : d.rCrit * 1.05
                    d.r = min(cap, d.r + dt * SP * 0.09 * feed)
                    if d.r >= d.rCrit { d.falling = true }
                } else {
                    d.r -= dt * SP * 0.05 * evaporation
                }
            } else {
                // Terminal velocity: drag rises with speed, and a bigger drop
                // carries more mass per unit of drag, so it falls faster.
                // v_t proportional to sqrt(r) is the standard result.
                let vTerm = 260 * sqrt(d.r / SP)
                d.v += (gravity * (1 - d.v / max(vTerm, 1))) * dt
                d.y += d.v * dt
                d.x += windPush * d.v * dt * 0.25     // wind skews the run
                // A running drop sheds a little of itself as the trail it
                // leaves, so it thins as it goes — and evaporates as well once
                // the rain has stopped.
                d.r = max(d.r * (1 - dt * 0.10) - dt * SP * 0.03 * evaporation, SP * 0.02)
            }
            drops[i] = d

            // ---- landing on furniture
            //
            // A falling drop that reaches the top edge of the dock, a widget or
            // the lock screen clock does not pass through it: it lands, throws
            // spray back up and outward, and leaves that edge wet. The furniture
            // draws over us, so what stays visible is the spray — which is the
            // whole point of knowing where these things are.
            if d.falling && d.splashLife == 0 && d.v > 4 {
                var landed = false
                let prevY = d.y - d.v * dt
                for k in 0..<surfaces.count where surfaces[k].spans(d.x) {
                    if prevY <= surfaces[k].top && d.y + d.r >= surfaces[k].top {
                        splash(at: d, on: k)
                        landed = true
                        break
                    }
                }
                if landed { drops.remove(at: i); i -= 1; continue }
            }

            // ---- the wet track
            //
            // Deposited along the whole path the drop covered this frame, not
            // into the one cell it happens to be in now. At terminal velocity a
            // drop crosses several cells per frame, so stamping only where it
            // ENDED left a dotted line of unconnected marks — which is exactly
            // why the tracks never read as tracks. A windscreen's tracks are
            // continuous, and continuity is most of what makes them legible.
            if d.falling && d.splashLife == 0 && d.v > 6 {
                let prevY = d.y - d.v * dt
                // A RATE, scaled by dt. Adding a fixed lump every frame meant
                // 60 deposits a second against a decay of 0.045 a second, so
                // the film could only ever saturate — the whole pane ended up
                // uniformly wet and never cleared.
                let strength = min(1, (d.r / (SP * 0.4)) * (d.v / 220))
                let span = max(SP * 0.5, d.y - prevY)
                let steps = min(24, max(1, Int(span / (SP * 0.5))))
                let each = strength * dt * 3.4 / Float(steps)
                for k in 0..<steps {
                    let f = Float(k) / Float(steps)
                    let yy = prevY + (d.y - prevY) * f
                    let xx = d.x - windPush * d.v * dt * 0.25 * (1 - f)
                    let cx = Int(xx / SP), cy = Int(yy / SP)
                    guard cx >= 0, cx < cols, cy >= 0, cy < rows else { continue }
                    let idx = cy * cols + cx
                    trailCells[idx] = min(1, trailCells[idx] + each)
                }
            }

            // The bottom edge is not a wall. Most drops merge into whatever
            // has pooled there, feeding it; a few carry enough momentum to run
            // over the lip and off the screen, which is what actually happens
            // on a wet pane.
            let poolTop = H - poolDepth * SP
            if d.y >= poolTop && d.falling && d.splashLife == 0 {
                if rnd() < 0.22 {
                    // Runs off the edge. Keeps falling until it is gone.
                    if d.y > H + SP * 2 { drops.remove(at: i); i -= 1; continue }
                } else {
                    poolDepth = min(maxPoolDepth, poolDepth + d.r / SP * 0.006)
                    if rnd() < 0.35 && spots.count < 90 {
                        spots.append(GlassSpot(x: d.x, y: min(H - 1, poolTop), r: d.r * 0.7, a: 0.5))
                    }
                    drops.remove(at: i); i -= 1; continue
                }
            }
            if d.y > H + SP * 3 || d.r < SP * 0.06 {
                drops.remove(at: i); i -= 1; continue
            }
            i -= 1
        }

        // Coalescence. A falling drop that catches a clinging one absorbs it:
        // volumes add, so radii add as cube roots. This is what makes a few
        // heavy runs instead of an even field of beads.
        var a = drops.count - 1
        while a >= 0 {
            guard a < drops.count, drops[a].falling else { a -= 1; continue }
            var b = drops.count - 1
            while b >= 0 {
                guard b != a, b < drops.count, a < drops.count else { b -= 1; continue }
                let A = drops[a], B = drops[b]
                let dx = A.x - B.x, dy = A.y - B.y
                if dx * dx + dy * dy < (A.r + B.r) * (A.r + B.r) {
                    let merged = pow(A.r * A.r * A.r + B.r * B.r * B.r, 1.0 / 3.0)
                    drops[a].r = merged
                    // Momentum carries across; the heavier drop keeps running.
                    drops[a].v = max(A.v, B.v) * 0.9
                    drops[a].rCrit = min(drops[a].rCrit, merged)
                    drops.remove(at: b)
                    if b < a { a -= 1 }
                }
                b -= 1
            }
            a -= 1
        }

        // dried spots persist until the next real rain washes them off
        if wet && inten > 0.6 && !spots.isEmpty {
            var j = spots.count - 1
            while j >= 0 {
                spots[j].a -= dt * 0.45
                if spots[j].a <= 0 { spots.remove(at: j) }
                j -= 1
            }
        }
        for sp in spots {
            let gx = (sp.x / SP).rounded(.down) * SP + SP * 0.5
            let gy = (sp.y / SP).rounded(.down) * SP + SP * 0.5
            glassQuads.append(GlassQuad(x: gx, y: gy, r: sp.r, kind: 3,
                                        alpha: sp.a * 0.13, _p0: 0, _p1: 0, _p2: 0))
            glassQuads.append(GlassQuad(x: gx, y: gy, r: sp.r * 1.25, kind: 4,
                                        alpha: sp.a * 0.10, _p0: 0, _p1: 0, _p2: 0))
        }

        // wind vortices, only when it is genuinely blowing
        let wind = w.wind
        if wind > 26 && vortices.count < 3 && rnd() < 0.012 * dt * 60 {
            vortices.append(GlassVortex(x: rnd() < 0.5 ? -SP * 4 : W + SP * 4,
                                        y: H * (0.2 + rnd() * 0.5),
                                        r: SP * (2.5 + rnd() * 3), t: 0,
                                        life: 5 + rnd() * 4,
                                        dir: w.windDir > 180 ? -1 : 1))
        }
        var k = vortices.count - 1
        while k >= 0 {
            vortices[k].t += dt
            if vortices[k].t > vortices[k].life { vortices.remove(at: k); k -= 1; continue }
            vortices[k].x += vortices[k].dir * dt * wind * 1.1
            vortices[k].y += sin(vortices[k].t * 1.7) * dt * SP * 1.2
            let v = vortices[k]
            let fade = sin(.pi * v.t / v.life)            // in and out, never popping
            for a in 0..<3 {
                let base = v.t * 3.1 + Float(a) * (6.2832 / 3)
                for s in 0..<7 {
                    let th = base + Float(s) * 0.42
                    let rr = v.r * (0.22 + Float(s) * 0.13)
                    let px = ((v.x + cos(th) * rr) / SP).rounded(.down) * SP + SP * 0.5
                    let py = ((v.y + sin(th) * rr * 0.55) / SP).rounded(.down) * SP + SP * 0.5
                    if px < -SP || px > W + SP { continue }
                    glassQuads.append(GlassQuad(x: px, y: py, r: SP * 0.20, kind: 5,
                                                alpha: fade * 0.16 * (1 - Float(s) / 7),
                                                _p0: 0, _p1: 0, _p2: 0))
                }
            }
            k -= 1
        }

        rasteriseGlass()
    }

    /// Stamp the glass elements onto the cell grid. Everything the presentation
    /// pass needs to draw water in the current theme, at one lookup per pixel.
    ///
    /// Stamp water into the per-cell grid as WETNESS, not as geometry.
    ///
    /// Earlier this recorded each drop's centre and radius so the detail pass
    /// could subdivide and draw a bead. That read as bright confetti scattered
    /// over the mosaic — the drops added light, so they popped as speckle and
    /// the fine subdivision fought the calm coarse grid.
    ///
    /// Water now changes the MATERIAL of the cells it touches instead of
    /// sitting on top of them as objects: a wet cell is the same cell, wetter.
    /// Nothing is ever pasted onto the grid, so every theme stays itself.
    ///
    /// Wetness falls off from each element's centre, so a drop leaves a soft
    /// patch rather than a hard disc, and the whole field is scaled by how hard
    /// it is actually raining — drizzle should be barely perceptible.
    private func rasteriseGlass() {
        guard !glassCells.isEmpty else { return }
        for i in 0..<glassCells.count { glassCells[i] = .zero }

        /// `bead` records where the cell sits inside the drop, as a vector from
        /// the drop's centre scaled by its radius. That is everything the shader
        /// needs to shade a bead out of whole cells — no subdivision, so the
        /// bead is made of the mosaic rather than drawn over it.
        func stamp(x: Float, y: Float, r: Float, kind: Float, strength: Float, bead: Bool = false) {
            let reach = max(r, SP * 0.5)
            let c0 = max(0, Int((x - reach) / SP)), c1 = min(cols - 1, Int((x + reach) / SP))
            let r0 = max(0, Int((y - reach) / SP)), r1 = min(rows - 1, Int((y + reach) / SP))
            guard c0 <= c1, r0 <= r1 else { return }
            for cy in r0...r1 {
                for cx in c0...c1 {
                    let dx = (Float(cx) + 0.5) * SP - x
                    let dy = (Float(cy) + 0.5) * SP - y
                    let d = (dx * dx + dy * dy).squareRoot() / reach
                    guard d <= 1 else { continue }
                    let w = strength * (1 - d * d)          // soft edge
                    let idx = cy * cols + cx
                    if w > glassCells[idx].x {
                        glassCells[idx] = SIMD4<Float>(min(1, w), kind,
                                                       bead ? dx / reach : 0,
                                                       bead ? dy / reach : 0)
                    }
                }
            }
        }

        // How hard it is actually coming down. Drizzle barely marks the pane;
        // a downpour soaks it. This is what makes the effect track the forecast
        // instead of being a fixed decoration.
        let intensity = min(1, max(rainIntensity, glassWet * 0.5))

        // The wet tracks, before anything else — droplets and pools draw over
        // them, which is the right order: the film is underneath.
        for i in 0..<min(trailCells.count, glassCells.count) where trailCells[i] > 0.02 {
            let v = min(0.75, trailCells[i] * 0.8)
            if v > glassCells[i].x { glassCells[i] = SIMD4<Float>(v, 2, 0, 0) }
        }

        // Standing water along the bottom edge.
        if poolDepth > 0.05 {
            let top = Float(rows) - poolDepth
            for cy in max(0, Int(top))..<rows {
                let depth = min(1, (Float(cy) - top + 1) / max(poolDepth, 0.5))
                for cx in 0..<cols {
                    let idx = cy * cols + cx
                    let v = 0.30 + depth * 0.45
                    if v > glassCells[idx].x { glassCells[idx] = SIMD4<Float>(v, 5, 0, 0) }
                }
            }
        }

        // Snow lying on the top edge of each surface.
        for s in surfaces {
            guard let cap = snowCap[s.kind.rawValue], cap > 0.05 else { continue }
            let rowTop = s.top / SP - cap
            let c0 = max(0, Int(s.left / SP)), c1 = min(cols - 1, Int(s.right / SP))
            guard c0 <= c1 else { continue }
            for cy in max(0, Int(rowTop))...max(0, Int(s.top / SP)) where cy < rows {
                for cx in c0...c1 {
                    let idx = cy * cols + cx
                    if 0.9 > glassCells[idx].x { glassCells[idx] = SIMD4<Float>(0.9, 6, 0, 0) }
                }
            }
        }

        for sp in spots  { stamp(x: sp.x, y: sp.y, r: sp.r, kind: 3, strength: sp.a * 0.30 * intensity) }
        for v in vortices {
            let fade = sin(.pi * v.t / v.life)
            guard fade > 0.05 else { continue }
            for a in 0..<3 {
                let base = v.t * 3.1 + Float(a) * (6.2832 / 3)
                for k in 0..<7 {
                    let th = base + Float(k) * 0.42
                    let rr = v.r * (0.22 + Float(k) * 0.13)
                    stamp(x: v.x + cos(th) * rr, y: v.y + sin(th) * rr * 0.55,
                          r: SP * 0.22, kind: 4, strength: fade * 0.22)
                }
            }
        }
        for d in drops {
            // The wet track a running drop leaves behind it.
            if d.falling && d.v > 40 {
                let len = min(SP * 3.5, d.v * 0.02)
                var t: Float = SP * 0.5
                while t < len {
                    stamp(x: d.x, y: d.y - t, r: d.r * 0.9, kind: 2,
                          strength: 0.55 * intensity * (1 - t / max(len, 1)))
                    t += SP * 0.5
                }
            }
            // Only mature drops read as beads: ones that have grown most of
            // the way to their critical radius, or are already running. Small
            // condensation just wets its cells, which is what it looks like in
            // life — you do not see a bead until it is big enough to hold a
            // shape. So beads show up at the right time and place instead of
            // peppering the whole pane.
            let mature = d.falling || d.r > d.rCrit * 0.72
            stamp(x: d.x, y: d.y, r: d.r * 1.15,
                  kind: mature ? 1 : 2,
                  strength: (mature ? 0.85 : 0.45) * intensity,
                  bead: mature)
        }
    }
}
