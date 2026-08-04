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
    var surfaces: [Surface] = []

    /// Grime settles out of dirty air onto every surface and washes off in
    /// rain, so a filthy week visibly builds up and one shower clears it.
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
    /// Snow lying on each kind of furniture, in cells.
    private(set) var snowCap: [Int32: Float] = [:]
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
    private func splash(at d: GlassDrop, on s: Surface) {
        splashCount += 1
        let impact = min(1, d.v / 260) * min(1, d.r / (SP * 0.5))
        guard impact > 0.06 else {
            surfaceWet[s.kind.rawValue, default: 0] = min(1, (surfaceWet[s.kind.rawValue] ?? 0) + 0.05)
            return
        }
        let n = min(5, 1 + Int(impact * 4))
        for _ in 0..<n {
            let sideways = (rnd() * 2 - 1) * d.v * 0.55
            let upward = -d.v * (0.25 + rnd() * 0.35)
            drops.append(GlassDrop(x: d.x + sideways * 0.01,
                                   y: s.top - SP * 0.15,
                                   r: d.r * (0.30 + rnd() * 0.25),
                                   v: upward,
                                   rCrit: d.rCrit,
                                   falling: true,
                                   vx: sideways,
                                   splashLife: 0.30 + rnd() * 0.35))
        }
        surfaceWet[s.kind.rawValue, default: 0] = min(1, (surfaceWet[s.kind.rawValue] ?? 0) + impact * 0.25)
    }

    /// How wet each kind of furniture currently is.
    private(set) var surfaceWet: [Int32: Float] = [:]
    /// Splash events since start — purely for verifying the collision path.
    private(set) var splashCount = 0

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

    private func updateGlass(dt rawDT: Float, state: SceneState) {
        glassQuads.removeAll(keepingCapacity: true)
        let dt = min(0.05, rawDT)
        let w = state.weather
        let code = w.code
        // Measured, not classified. The code alone used to be enough to soak
        // the pane on a dry day.
        let wet = w.isPrecipitating
        let inten: Float = wet ? max(0.12, min(1, 0.12 + w.precipAmount / 4)) : 0
        // Genuine intensity, not the floored spawn rate: 0.1mm drizzle should
        // read as almost nothing, 5mm as a soaking.
        rainIntensity = wet ? min(1, w.precipAmount / 5) : 0

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

        // ---- droplets ------------------------------------------------------
        // Seeding: new drops arrive at a rate set by the rainfall, small.
        if wet && drops.count < 90 && rnd() < inten * 0.9 * dt * 60 {
            let r0 = SP * (0.14 + rnd() * 0.12)
            drops.append(GlassDrop(x: rnd() * W, y: rnd() * H * 0.85,
                                   r: r0, v: 0,
                                   // Spread of critical radii stands in for a
                                   // real surface: some spots hold a bigger
                                   // bead than others.
                                   // Critical radius is a fraction of a cell, so
                                   // drops stay legible as mosaic elements at any
                                   // grid pitch rather than shrinking to specks.
                                   rCrit: SP * (0.34 + rnd() * 0.30),
                                   falling: false))
        }

        let gravity: Float = 900              // px/s^2
        let windPush = w.wind / 90
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
                if inten > 0.01 {
                    d.r += dt * SP * 0.09 * inten
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
                for surf in surfaces where surf.spans(d.x) {
                    let prevY = d.y - d.v * dt
                    if prevY <= surf.top && d.y + d.r >= surf.top {
                        splash(at: d, on: surf)
                        landed = true
                        break
                    }
                }
                if landed { drops.remove(at: i); i -= 1; continue }
            }

            if d.falling && d.splashLife == 0 && d.v > 6 {
                let cx = Int(d.x / SP), cy = Int(d.y / SP)
                if cx >= 0, cx < cols, cy >= 0, cy < rows {
                    // A RATE, scaled by dt. Adding a fixed lump every frame
                    // meant 60 deposits a second against a decay of 0.045 a
                    // second, so the film could only ever saturate — the whole
                    // pane ended up uniformly wet and never cleared.
                    let strength = min(1, (d.r / (SP * 0.4)) * (d.v / 220))
                    let idx = cy * cols + cx
                    trailCells[idx] = min(1, trailCells[idx] + strength * dt * 2.2)
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
