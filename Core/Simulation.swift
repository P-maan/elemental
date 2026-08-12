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
    /// Dew. The same mechanism as fog and the far more common one: the air is
    /// not obscured, but the surface has fallen below the dew point and the
    /// vapour touching it gives up its water. An even film of very small
    /// droplets on every face, arriving out of the air rather than falling onto
    /// it, and it appears on a clear calm night precisely because that is when a
    /// surface radiates itself coldest.
    case dew
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

    /// Is this form actively putting liquid water onto a surface right now?
    ///
    /// If it is, the evaporation term must not run in the same frame, or the
    /// two fight: dew condensed at 0.013/s while the dryer took 0.011/s back
    /// out, so after two minutes of a perfect dew night the lip had 0.24 of a
    /// film and was still climbing at a fifth of the rate it should have. The
    /// deposit was correct, the balance was not, and the symptom was simply
    /// "not very visible" — which is the hardest kind of wrong to spot.
    var deposits: Bool {
        switch self {
        case .rain, .drizzle, .hail, .fog, .dew, .freezingRain: return true
        case .sleet, .snow, .frost, .dust, .none: return false
        }
    }

    /// The most liquid water an impact of this kind can leave on a lip, 0..1.
    ///
    /// An impact deposits what did not bounce away, and for most of these that
    /// is almost nothing: an ice pellet is frozen through and leaves a dry
    /// rattle, a snowflake is not liquid at all. Without this ceiling the splash
    /// path simply added wetness on every strike whatever was striking, and six
    /// thousand frames of a snowstorm left the dock reporting a soaking wet,
    /// running lip at -4°C — the arrival physics said one thing and the
    /// collision physics quietly overruled it.
    var liquidCeiling: Float {
        switch self {
        case .rain:         return 1.0
        case .hail:         return 0.60   // meltwater, and plenty of it
        case .freezingRain: return 0.45   // most of it sets as ice instead
        case .fog, .dew:    return 0.35
        case .drizzle:      return 0.25   // wets, never gathers
        case .sleet:        return 0.12   // bounces off nearly dry
        case .snow:         return 0.05
        case .frost, .dust, .none: return 0.10
        }
    }

    /// Does it clean a surface off, or add to what is on it?
    ///
    /// Only water arriving with enough volume and momentum to carry dirt away.
    /// Drizzle wets the dirt without moving it — which is why a drizzled car
    /// comes out streakier than a dry one — and a glaze seals it underneath.
    var washes: Bool { self == .rain || self == .hail }
}

/// The weather as a LIP feels it, worked out once a frame from measured
/// quantities.
///
/// Every field here is derived from something an instrument reported — a fall
/// speed, a dew point, a cloud cover, a wind — and never from a WMO code or a
/// scene category. That is the whole discipline: a code says what someone
/// decided to call the hour, and a surface responds to what actually hit it.
///
/// Anything that cannot be derived because the reading is missing degrades to
/// the value that makes NOTHING happen, rather than to a plausible default.
/// A missing cloud cover must not be allowed to invent a frost.
struct SurfaceWeather {
    /// What the lip itself is at, °C.
    ///
    /// No surface in this engine carries a temperature, so this is the air
    /// temperature minus the radiative deficit a surface facing an open sky
    /// runs at. That deficit is not a detail: it is the entire reason frost
    /// appears on a clear calm night and not on a cloudy windy one at the same
    /// air temperature.
    var surfaceTemp: Float = 20
    /// Median drop diameter, mm. Inverted from the MEASURED fall speed rather
    /// than assumed from the form — Atlas & Ulbrich, v = 3.78 D^0.67 at sea
    /// level. This is what decides whether water beads or lies flat.
    var dropDiameter: Float = 0
    /// 0 discrete beads, 1 a continuous sheet. A surface sheets when water
    /// arrives faster than the lip can shed it.
    var sheeting: Float = 0
    /// Can what is landing actually run? Below about 0.6mm surface tension
    /// wins outright and the drop stays where it lands however much of it
    /// arrives, which is why drizzle is matte and light rain is glossy.
    var canRun = false
    /// How hard the air is giving up water onto the surface, 0..1. The measured
    /// test is dew point against SURFACE temperature; relative humidity on its
    /// own would put frost on a warm monsoon night.
    var condensing: Float = 0
    /// Is the lip at or below freezing? Decides deposition versus condensation,
    /// and glaze versus run-off.
    var freezing: Bool { surfaceTemp <= 0 }
    /// Which way water is being driven along the lip, -1..1. Zero in still air:
    /// spray then goes straight up, which is a different picture entirely.
    var drive: Float = 0
    /// How much of the water is thrown horizontally rather than dropped, 0..1.
    var driven: Float = 0
    /// How loose the snow lies. A dendrite bulks up deep and open; graupel is
    /// rimed and nearly spherical and packs dense and shallow.
    var snowBulk: Float = 1
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
    /// How much of the lip the snow still covers, 0..1.
    ///
    /// Depth and EXTENT are separate, because a thawing cap does not thin
    /// evenly — it retreats from the ends, where the edge sees warm air on
    /// three sides instead of one. A cap that only lost depth would fade like a
    /// dimmer being turned down; a cap that also loses span visibly shrinks back
    /// toward the middle of the lip, which is what a real one does.
    var snowSpan: Float = 0
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

    // Falling hydrometeors.
    //
    // `wob`/`ph` are the sideways wander a slow crystal describes on the way
    // down — a dendrite at 0.8 m/s in any breeze at all does not fall, it
    // drifts. `hops` counts rebounds, so a hailstone bounces once off the
    // bottom edge and then behaves.
    private var streaks: [(c: Float, y: Float, len: Float, v: Float,
                           slope: Float, wob: Float, ph: Float, hops: Float)] = []

    /// How much precipitation is arriving at each COLUMN right now, 0..1.
    ///
    /// This is where MORPHOLOGY lives. Steady frontal rain fills it almost
    /// flat, because uniform in space and continuous in time is what frontal
    /// rain IS; a shower puts cells in it with genuinely dry gaps between them;
    /// a squall puts narrow bands in it that sweep across; drizzle is the most
    /// uniform thing there is and fills it completely.
    ///
    /// Streaks are placed by rejection against this, so a dry gap places
    /// nothing at all rather than merely placing dimmer rain — which is the
    /// difference between scattered showers and weak steady rain.
    private(set) var precipField: [Float] = []

    /// Fractional carry on the spawn rate, so it is a RATE rather than "at most
    /// one streak per frame". See updateStreaks.
    private var spawnAccum: Float = 0

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
        let fMin = precipField.min() ?? 0
        let fMean = precipField.isEmpty ? 0 : precipField.reduce(0, +) / Float(precipField.count)
        return String(format: "T=%.0f RH=%.0f Td=%.1f wind=%.0f uv=%.1f evap=%.3f vpd=%.2f | surfaces=%d splashes=%d streaks=%d lit=%d drops=%d | film mean=%.3f peak=%.2f wet>0.15=%d/%d "
                            + "| pool=%.2f spots=%d grid=%dx%d | field min=%.2f mean=%.2f dryCols=%d",
                      lastWeather.temperature, lastWeather.humidity, lastWeather.dewPoint,
                      lastWeather.wind, lastWeather.uv,
                      lastWeather.evaporationRate, lastWeather.vapourPressureDeficit,
                      surfaces.count, splashCount, streaks.count, lit, drops.count, mean, peak, wet, trailCells.count,
                      poolDepth, spots.count, cols, rows,
                      fMin, fMean, precipField.filter { $0 < 0.05 }.count)
            + "\n" + surfaceSummary
            + "\n" + lastWeather.presentationSummary
    }

    /// What the furniture is actually carrying. Without this the only way to
    /// check a deposit is to squint at a PNG and hope.
    var surfaceSummary: String {
        let sw = surfaceWeather
        var s = String(format:
            "  furniture form=%@ Tsurf=%.1f (air %.1f) Td=%.1f drop=%.2fmm sheet=%.2f "
            + "run=%@ cond=%.2f drive=%+.2f bulk=%.2f",
            String(describing: form), sw.surfaceTemp, lastWeather.temperature,
            lastWeather.dewPoint, sw.dropDiameter, sw.sheeting,
            sw.canRun ? "y" : "n", sw.condensing, sw.drive, sw.snowBulk)
        for (i, f) in films.enumerated() {
            s += String(format:
                "\n    [%d %@] wet=%.2f lip=%.2f run=%.2f snow=%.2f/%.2f glaze=%.2f frost=%.2f grime=%.2f steam=%.2f imp=%.2f",
                i, String(describing: surfaces[i].kind),
                f.wet, f.lip, f.runoff, f.snow, f.snowSpan,
                f.glaze, f.frost, f.grime, f.steam, f.impact)
        }
        return s
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
    /// Scene time at the current step, for the presentation pass — beads on a
    /// lip swell and slide, and that has to be a function of time rather than
    /// of the frame counter or it flickers instead of moving.
    private var simSec: Float = 0
    /// Sun altitude and view heading, kept for the surface-energy terms. A lip
    /// only runs colder than the air once the sun is off it.
    private var sunAlt: Float = 0
    private var facingAz: Float = 180
    /// The measured picture the furniture responds to. Recomputed once a frame.
    private(set) var surfaceWeather = SurfaceWeather()
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
    //
    //  There used to be a `snowCap: [Int32: Float]` here, keyed by Surface.Kind
    //  and left permanently empty by an interrupted edit so its read site could
    //  never fire. Keying by KIND was the wrong shape anyway: two widgets in
    //  different places catch different amounts, and one number per kind averages
    //  exactly the difference that makes them worth drawing. Accumulation now
    //  lives in `SurfaceFilm.snow`/`snowSpan`, one per surface, alongside every
    //  other thing that collects on a lip.
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
    /// The mosaic grid a display of this size and row count produces.
    ///
    /// Static and public because the furniture detector needs to know where the
    /// grout lines are — it finds the dock and the widgets by asking which of
    /// OUR cell boundaries the screenshot has lost. Two independent derivations
    /// of the same grid is exactly the kind of thing that drifts, so there is
    /// one.
    static func gridGeometry(pixelWidth: Float, pixelHeight: Float,
                             gridRows: Int) -> (cols: Int, rows: Int, pitch: Float) {
        var sp = max(6, (pixelHeight / Float(max(1, gridRows))).rounded())
        let r = max(1, Int((pixelHeight / sp).rounded()))
        sp = pixelHeight / Float(r)
        return (max(1, Int((pixelWidth / sp).rounded())),
                max(1, Int((pixelHeight / sp).rounded())), sp)
    }

    func resize(pixelWidth: Float, pixelHeight: Float, gridRows: Int) {
        let g = SceneSimulation.gridGeometry(pixelWidth: pixelWidth,
                                             pixelHeight: pixelHeight, gridRows: gridRows)
        let sp = g.pitch
        rows = g.rows
        cols = g.cols
        SP = sp
        H = Float(rows) * sp
        W = Float(cols) * sp
        edgeArr = [Float](repeating: 0, count: cols)
        precipField = [Float](repeating: 1, count: cols)
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
        spawnAccum = 0
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
        spawnAccum = 0
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
        simSec = sec
        // Pick up an edited config. `Furniture.poll` documents itself as being
        // called from the simulation's step "which is the one place that runs in
        // every host" — and it was called from nowhere at all, so every one of
        // the wetDock / wetWidgets / wetMenuBar / paneWater switches was inert
        // and `Furniture.options` sat on its compiled-in defaults forever. It
        // stats the file at most once every five seconds and decodes only when
        // the timestamp has actually moved.
        Furniture.poll(now: TimeInterval(sec))
        let w = state.weather
        lastWeather = w
        let covF = state.covF
        let sAlt = state.astro.sunAlt
        sunAlt = sAlt
        facingAz = state.facingAz

        // The hanging deck is the LOW layer, and ONLY the low layer. The
        // `max(..., covF * 0.25)` floor that used to be here defeated the point:
        // it meant 90% high cirrus still grew a quarter-strength lid, so the two
        // skies the altitude split exists to separate came out looking alike.
        //
        // The one case total cover is still needed for is a report that gives a
        // cover figure with no breakdown — an older cache, a partial fetch. Then
        // it all goes in the low deck, matching the same fallback in Renderer,
        // because that is the reading that hides the most.
        var deckCover = w.cloudLow / 100
        if w.cloudLow + w.cloudMid + w.cloudHigh < 2 && w.cover > 2 { deckCover = covF }
        deckCover = max(0, min(1, deckCover))
        updateCloudEdge(sec: sec, covF: deckCover, weather: w)
        updateStreaks(dt: dt, kind: w.effectiveKind, weather: w,
                      facingAz: state.facingAz, sec: sec)
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
    private func updateCloudEdge(sec: Float, covF: Float, weather w: WeatherState) {
        let wind = w.wind
        // ---- how LOW the deck sits, from the measured cloud base.
        //
        // A ceiling is a metres-above-ground measurement of where the cloud
        // actually is, taken by an instrument at an aerodrome. It is the whole
        // reason Observation.swift decodes cloud layers at all, and until now
        // nothing downstream read it. Out of a window a 200m base is a lid you
        // can almost touch that fills the view; the same cover at 3km is a flat
        // grey ceiling well above the roofline.
        //
        // -1 means nobody measured one, and that has to leave the profile
        // EXACTLY as it was rather than defaulting to either extreme.
        var lowness: Float = 1
        if w.ceiling >= 0 {
            let f = max(0, min(1, (w.ceiling - 150) / 2400))
            lowness = 1.30 - 0.48 * f              // 1.30 on the deck, 0.82 by 2.5km
        }
        // ---- the LEAD and the LAG. The user's own description of rain is a
        // sequence: the grey comes over, then it gets dark, then it rains — and
        // the deck does not evaporate the moment the rain stops. So the deck
        // grows before the first drop and lingers after the last one.
        let arc = max(w.approachProgress, w.clearingProgress * 0.7)

        // How far down the frame the deck can hang.
        //
        // This was `H * (0.10 + 0.38 * covF)`, so the lower edge bottomed out at
        // 48% of the frame — a hundred per cent overcast left the bottom half of
        // the window as open sky, which is not a thing that happens. A closed
        // deck is closed: there is no horizon gap to see out of.
        //
        // Cubic, so the growth is where it belongs. Scattered cloud stays a
        // shallow fringe along the top, and only as cover approaches total does
        // the deck run past the bottom of the frame — at 100% the shallowest
        // column still lands well below H, so no clear sky survives anywhere.
        let depth = H * (0.10 + covF * (0.35 + 1.10 * covF * covF))
                     * lowness * (1 + 0.22 * arc)
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

    /// Where the rain IS, across the frame, right now.
    ///
    /// Steady frontal rain and a scattered afternoon shower deliver the same
    /// millimetres and look nothing alike, and the difference is entirely in
    /// how the water is distributed in space and in time. That difference has
    /// to be built here, at the point where hydrometeors are placed, because no
    /// amount of shading downstream can put a dry gap into a field that was
    /// seeded uniformly.
    ///
    /// `patchiness` sets the contrast and `bandedness` the organisation; both
    /// come from `WeatherState`, which derives them from an observer's
    /// present-weather group, the measured run structure of the nowcast, or the
    /// model's own convective millimetres — never from a WMO code.
    private func updatePrecipField(sec: Float, weather w: WeatherState) {
        guard !precipField.isEmpty else { return }
        let patch = w.patchiness
        let band = w.bandedness

        // Cells and bands are carried past the window by the wind. The constant
        // term is there so a shower in dead calm still opens and closes rather
        // than standing over the house forever.
        let drift = sec * (0.012 + min(0.09, w.wind * 0.006))

        // How much of the structure survives. At `patchiness` 0 the field is
        // flat — uniform is what frontal rain IS, not a failure to be
        // interesting — and by 0.7 the gaps run all the way down to dry.
        let shape = min(1, patch * 1.45)
        let gate = patch * 0.72
        let span = max(0.18, 1 - gate)
        let inv = 6.2832 / Float(max(1, cols))

        for c in 0..<cols {
            let a = Float(c) * inv
            // Three scales. The longest is WIDER THAN THE FRAME, so the whole
            // view can go quiet at once — a shower that only ever moved from one
            // side of the window to the other would never actually stop, and
            // stopping is most of what makes a shower a shower.
            let n = 0.50
                  + 0.30 * sin(a * 0.6 + drift * 0.55 + 0.7)
                  + 0.22 * sin(a * 2.3 - drift * 0.90 + 2.4)
                  + 0.14 * sin(a * 6.1 + drift * 1.60 + 5.1)
            var v = max(0, min(1, (n - gate) / span))
            v = 1 - shape * (1 - v)
            if band > 0.01 {
                // A squall line is a LINE, not a blotch: narrow crests, high
                // contrast, moving fast. The rain arrives as a wall and leaves
                // as one, which is why a squall is over in minutes.
                let s = sin(a * 1.4 + drift * 2.6 + 1.1)
                let crest = s > 0 ? s * s * s : 0
                v = max(v * (1 - band * 0.8), crest * min(1, 0.45 + band))
            }
            precipField[c] = max(0, min(1, v))
        }

        // ---- What the radar actually sees, over the top of what we invented.
        //
        // Everything above is a plausible distribution: patchiness and
        // bandedness shaped into showers and gaps that are statistically right
        // for the weather type and spatially arbitrary. It has to be, because
        // nothing else in this project knows where the rain IS — a model gives
        // a rate for a grid box tens of kilometres wide and a METAR gives one
        // aerodrome.
        //
        // Radar knows. The profile is echo across roughly 900 km centred on the
        // user, so resampling it onto the frame's columns puts the shower that
        // is off to the west off to the west, and makes the gap between two
        // cells a real gap. This is the difference between a sky that is
        // statistically like the one outside and the one that is outside.
        //
        // BLENDED, not substituted, and for two honest reasons. The radar window
        // is far wider than the strip of sky a window actually shows, so using it
        // raw would compress a whole frontal system into the frame; and radar has
        // speckle and beam artefacts that the procedural field does not. So it
        // biases where the rain falls rather than dictating it, and with no radar
        // at all the field is exactly what it was.
        let prof = w.radarProfile
        guard prof.count >= 4 else { return }
        for c in 0..<cols {
            // Centre of the frame maps to the centre of the radar window, and
            // the frame spans a modest slice of it — a window looks at a piece
            // of sky, not at a synoptic chart.
            let t = (Float(c) / Float(max(1, cols - 1)) - 0.5) * 0.42 + 0.5
            let fi = t * Float(prof.count - 1)
            let i0 = max(0, min(prof.count - 1, Int(fi)))
            let i1 = min(prof.count - 1, i0 + 1)
            let f = fi - Float(i0)
            let echo = prof[i0] * (1 - f) + prof[i1] * f
            // Echo is thin in absolute terms even in steady rain, so it is
            // taken as a PRESENCE curve rather than an amplitude.
            let here = min(1, echo / 0.22)
            precipField[c] = max(0, min(1, precipField[c] * (0.35 + 0.65 * here)))
        }
    }

    private func updateStreaks(dt: Float, kind: SceneKind,
                               weather: WeatherState, facingAz: Float, sec: Float) {
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
            // Dropped, not banked. Carrying the fraction across a dry spell
            // would fire a dozen streaks at once the moment it started again.
            spawnAccum = 0
            return
        }
        streakGridLive = true
        updatePrecipField(sec: sec, weather: weather)

        let form = weather.precipForm
        let rate = weather.precipRate

        // ---- HOW FAST. From the measured terminal fall speed rather than from
        // the scene category, so a dendrite and a hailstone stop being the same
        // object at two intensities. Gunn & Kinzer for liquid, Barthazy &
        // Schefold's habit coefficients for snow; see WeatherState.fallSpeed.
        //
        // 0.30 is the only scale factor in here, and it is chosen to land on the
        // speeds the scene was already tuned at: 7 m/s rain comes out at 2.1
        // cells a frame, 1 m/s snow at 0.30, and 14 m/s hail at 4.2 — which is
        // as violent as it should be.
        let baseSpeed = max(0.10, min(4.5, weather.fallSpeed * 0.30))

        // ---- HOW LONG A LINE IT DRAWS. `streakLength` is speed and rate
        // together, which is right for water; a compact hydrometeor is not a
        // column of it, however fast it comes down.
        var lenBase = 1.2 + weather.streakLength * 9
        switch form {
        case .hail, .icePellets, .graupel, .snowGrains: lenBase = min(lenBase, 1.8)
        case .snow:    lenBase = min(lenBase, 2.2)   // a flake, not a line
        case .drizzle: lenBase = min(lenBase, 2.0)   // too small and slow to streak
        default: break
        }

        // ---- HOW MUCH OF IT, as a rate per second with a fractional carry.
        //
        // The old code could start AT MOST ONE STREAK PER FRAME whatever the
        // weather, so the population settled near fifteen and a downpour was
        // indistinguishable from a shower. Drizzle is the opposite case: very
        // many, very small, very slow — dense enough to be a texture rather
        // than a set of lines.
        let density = max(0, min(1, rate / 8))
        let perSecond: Float = form == .drizzle ? (60 + 120 * density)
                                                : (25 + 400 * density)
        let maxStreaks = form == .drizzle ? 220 : Int(40 + 230 * density)

        // Wind direction relative to facing: eastward drifts right. Slope is
        // horizontal cells per vertical cell — the ratio of the wind's push to
        // the fall speed — so fast rain in light wind is near vertical and slow
        // snow in a gale goes almost sideways.
        let relWind = ((weather.windDir - facingAz + 180 + 360)
                        .truncatingRemainder(dividingBy: 360)) - 180
        let driftSign: Float = weather.wind > 8
            ? (relWind > 0 ? 1 : -1) * min(1, abs(relWind) / 90) : 0
        let push = driftSign * (weather.wind / 22)
        let slope = max(-2.5, min(2.5, push / max(baseSpeed, 0.05)))
        // Wander. `flutter` is the ratio of the wind to the fall speed, and the
        // wind's steady push is already in `slope` — what is left is TUMBLE,
        // and tumble is a property of the shape rather than of the weather. A
        // branched crystal is unstable in a way a sphere is not; a drizzle drop
        // is a sphere, and it goes sideways without wiggling on the way.
        let tumble: Float
        switch weather.snowHabit {
        case .dendrite:              tumble = 1.00
        case .plate:                 tumble = 0.80
        case .columnar:              tumble = 0.60
        case .needle, .wetAggregate: tumble = 0.45
        case .graupel:               tumble = 0.15   // rimed, dense, nearly a sphere
        case .none:                  tumble = 0.12   // liquid and pellets
        }
        // Squared, so it is the SLOW things that wander: rain at 7 m/s barely
        // notices a breeze, a dendrite at 0.8 goes wherever it is sent.
        let wobble = weather.flutter * weather.flutter * 2.4 * tumble

        spawnAccum += perSecond * dt
        // Bounded, so one long frame cannot turn into a burst.
        spawnAccum = min(spawnAccum, 12)
        while spawnAccum >= 1 {
            spawnAccum -= 1
            guard streaks.count < maxStreaks else { break }
            // Pick a column WEIGHTED BY THE FIELD, by rejection. A dry gap
            // simply fails to place anything — which is what makes the gap dry
            // rather than merely dimmer, and dimmer is not what a shower does.
            var col = -1
            for _ in 0..<4 {
                let t = Int(rnd() * Float(cols))
                guard t >= 0, t < cols, edgeArr[t] > 0 else { continue }
                if rnd() < precipField[t] { col = t; break }
            }
            guard col >= 0 else { continue }

            // Rain falls out of the BASE of the deck — but once the deck hangs
            // past the bottom of the frame, the whole view is underneath it and
            // the rain has to start at the top instead of below a base that is
            // off screen.
            //
            // This was a real, total failure: the spawn row was the deck edge
            // in cells, the deck edge under heavy cover runs to about 1.4x the
            // frame height, so every streak was born below the last row and
            // deleted on the same frame it was created. At 95% cover — i.e.
            // whenever it is actually raining — the scene drew no rain at all.
            let deckRow = edgeArr[col] / SP
            let y0 = deckRow * max(0, 1 - deckRow / Float(rows))

            streaks.append((c: Float(col), y: y0,
                            len: lenBase * (0.75 + rnd() * 0.5),
                            v: baseSpeed * (0.72 + rnd() * 0.56),
                            slope: slope * (0.85 + rnd() * 0.3),
                            wob: wobble * (0.4 + rnd() * 1.2),
                            ph: rnd() * 6.2832,
                            hops: 0))
        }

        let f = dt * 60           // reference integrates per frame at 60fps
        // Ice bounces and water does not. Almost all of a hailstone's momentum
        // comes back off the ground and almost none of its mass stays, and that
        // rebound is the whole visible signature of hail.
        let bounces = (form == .hail || form == .icePellets || form == .graupel)
        let floorRow = Float(rows)
        var i = streaks.count - 1
        while i >= 0 {
            // A rebounding fragment is the one thing in the sky that is not at
            // terminal velocity, so it alone gets gravity.
            if streaks[i].v < 0 { streaks[i].v += 0.16 * f }
            let dy = streaks[i].v * f
            streaks[i].y += dy
            // The head travels along the slope, so the whole streak leans.
            streaks[i].c += streaks[i].slope * dy

            if bounces && streaks[i].hops < 1
                && streaks[i].v > 0 && streaks[i].y >= floorRow {
                streaks[i].hops = 1
                streaks[i].y = floorRow
                streaks[i].v = -streaks[i].v * (0.30 + rnd() * 0.25)
                streaks[i].slope = (rnd() - 0.5) * 1.2
                streaks[i].len = min(streaks[i].len, 1.4)
                streaks[i].wob = 0
                i -= 1
                continue
            }
            if streaks[i].y - streaks[i].len > floorRow
                || streaks[i].y < -8
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
            let wobbly = s.wob > 0.08
            while k < s.len {
                let ry = s.y - k
                let row = ry * fn
                // The wander is a function of WHERE the point is, not of how
                // old it is, so a fluttering crystal traces one fixed wavy path
                // down the frame instead of shivering in place.
                let wob = wobbly ? s.wob * sin(s.ph + ry * 0.55) : 0
                let col = (s.c - s.slope * k + wob) * fn + (fn - 1) * 0.5
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
        // What an impact may leave behind is decided by WHAT IS FALLING, not by
        // how hard it hit. See DepositForm.liquidCeiling.
        //
        // A CEILING ON THE CONTRIBUTION, never a clamp on the film. Written as
        // `min(cap, v + d)` it silently deleted whatever was already there:
        // the moment the rain stopped, the first stray pane droplet to land on
        // a soaking dock dragged it from 1.00 down to the 0.10 that "nothing
        // falling" is allowed to deposit, and the whole drying curve — an hour
        // of evaporation physics — collapsed into under a second. An impact can
        // raise a film toward its ceiling; it can never take one away.
        let cap = form.liquidCeiling
        func raise(_ v: inout Float, _ d: Float) { v = max(v, min(cap, v + d)) }
        guard impact > 0.05 else {
            raise(&films[i].lip, 0.04)
            return
        }
        // Bounce fraction: liquid stays, ice comes back.
        // Scaled by the FACE it struck. A hard smooth slab throws spray back;
        // a soft or textured one takes it. This is what makes the dock the
        // splashiest thing on screen and the menu bar the quietest.
        let bounce: Float = min(0.95, (form == .hail ? 0.85 : (form == .sleet ? 0.7 : 0.35))
                                      * s.material.rebound)
        let n = min(7, 1 + Int(impact * (form == .hail ? 6 : 4)))
        for _ in 0..<n {
            let sideways = (rnd() * 2 - 1) * d.v * (0.45 + bounce * 0.5)
            // How high it goes. Gravity here is 900 px/s², so the old
            // coefficients threw a fragment about twenty pixels — barely one
            // cell — and every splash in the scene was hidden behind the lip
            // that made it. Spray you cannot see over the edge is spray that
            // does not exist. These reach two to five cells, which is a splash.
            //
            // Aimed at a HEIGHT, not scaled off the fall speed.
            //
            // `-d.v * (0.45 + ...)` is proportional to how fast the drop was
            // going, and the note above — "these reach two to five cells" — was
            // worked out for a raindrop at full fall speed. Drizzle arrives at
            // about 84 px/s, and against gravity of 900 px/s^2 that is a rise of
            // v^2/2g = SIX PIXELS: a quarter of one cell, entirely inside the lip
            // that made it. Every offscreen test used --rain 8, so this never
            // showed; the live sky was WMO 51 at 0.2 intensity, which is drizzle,
            // and the dock got spray that physically could not clear its own
            // edge.
            //
            // So solve for the rise instead. A cell and a bit at the bottom of
            // the range, four or so at the top, converted to the launch speed
            // that actually reaches it: v = sqrt(2 g h). Drizzle still throws
            // less than a downpour — the range is keyed off the same impact
            // speed — but the floor is now "visible" rather than "nothing".
            let riseCells = 1.3 + 2.6 * min(1, d.v / 260)
            let vUp = (2 * 900 * SP * riseCells).squareRoot()
            let upward = -vUp * (0.78 + rnd() * 0.38)
            drops.append(GlassDrop(x: d.x + sideways * 0.01,
                                   y: s.top - SP * 0.15,
                                   r: d.r * (0.30 + rnd() * 0.25),
                                   v: upward,
                                   rCrit: d.rCrit,
                                   falling: true,
                                   vx: sideways,
                                   splashLife: 0.30 + rnd() * 0.40))
        }
        raise(&films[i].lip, impact * 0.30 * (1 - bounce))
        raise(&films[i].wet, impact * 0.18 * (1 - bounce))
        raise(&films[i].runoff, impact * 0.20 * (1 - bounce))
    }

    /// Splash events since start — purely for verifying the collision path.
    private(set) var splashCount = 0

    /// Fractional carry on the spray rate, so it is a rate rather than "at most
    /// one splash per frame". Same reason as `spawnAccum`.
    private var sprayAccum: Float = 0

    /// Spray thrown off a lip by the rain that is actually falling on it.
    ///
    /// The pane carries at most `maxDrops` droplets seeded at random across the
    /// whole screen, so waiting for one of THOSE to happen to land on the dock
    /// gave a splash every few seconds in a downpour — the dock behaved as if it
    /// were under a leaky roof rather than out in the rain. The sky is raining
    /// on the whole lip, so the spray rate comes from the rainfall and from how
    /// wide the lip is, and the pane droplets are then a bonus on top.
    ///
    /// Only where the rain actually IS: the column is tested against
    /// `precipField`, so a lip standing in the dry gap between two showers stays
    /// dry, which is the entire point of having a field.
    private func impactSpray(dt: Float, w: WeatherState) {
        guard form.impacts, films.count == surfaces.count, !surfaces.isEmpty else {
            sprayAccum = 0
            return
        }
        guard Furniture.options.furniture > 0.001, SP > 0 else { return }
        // Measured rate, not the category. 0.2mm/h throws essentially nothing.
        let rate = min(1, w.precipAmount / 5)
        guard rate > 0.015 else { sprayAccum = 0; return }

        // How much lip there is to be rained on, as a fraction of the frame's
        // width. A dock spanning most of the screen catches far more than one
        // small widget, and that ratio is the whole of why they look different.
        var lipWidth: Float = 0
        // Weighted by each lip's own wetness, so a widget turned down throws
        // proportionally less spray rather than the same amount as its neighbour.
        for s in surfaces where marks(s.kind) { lipWidth += s.w * max(0, min(1, s.wetness)) }
        guard lipWidth > 0 else { sprayAccum = 0; return }
        let widthFrac = min(2.5, lipWidth / max(W, 1))

        // Hail arrives fast and hard and its whole visible signature is the
        // rebound, so it strikes far more often for the same millimetres.
        let burst: Float = (form == .hail) ? 3.0 : (form == .sleet ? 1.8 : 1.0)
        sprayAccum += dt * (2 + 26 * rate) * widthFrac * burst
        sprayAccum = min(sprayAccum, 6)

        while sprayAccum >= 1 {
            sprayAccum -= 1
            guard drops.count < Self.maxDrops + 28 else { sprayAccum = 0; return }
            // Pick a lip, weighted by width, then a point along it.
            var pick = rnd() * lipWidth
            var idx = -1
            for (k, s) in surfaces.enumerated() where marks(s.kind) {
                if pick < s.w { idx = k; break }
                pick -= s.w
            }
            guard idx >= 0 else { continue }
            let s = surfaces[idx]
            let x = s.left + pick
            // Is it raining on THIS column right now?
            let c = Int(x / SP)
            if c >= 0, c < precipField.count, rnd() > precipField[c] { continue }

            // A synthetic arrival with the fall speed the sky actually has, so
            // a drizzle drop cannot throw a hailstone's spray.
            let v = max(40, min(520, w.fallSpeed * 42))
            // Big enough that its FRAGMENTS survive. splash() breaks a drop into
            // pieces 0.30-0.55 of its radius and the droplet loop deletes
            // anything under 0.06 SP, so a source drop below about a quarter of
            // a cell shatters into nothing and the splash is silent.
            let r = SP * (0.28 + rnd() * 0.26) * (form == .hail ? 1.5 : 1)
            splash(at: GlassDrop(x: x, y: s.top, r: r, v: v,
                                 rCrit: SP * 0.5, falling: true),
                   on: idx)
        }
    }

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
    ///
    /// This used to re-derive the answer from the WMO code — 96 is hail, 51-55
    /// is drizzle, and "under 0.35mm in light wind" is drizzle too, which
    /// confuses a drop SIZE with a rate. That is exactly the
    /// classification-over-measurement mistake the rest of the engine exists to
    /// avoid, and it disagreed with `WeatherState.precipForm`, which had already
    /// answered the same question from an observer's present-weather group, the
    /// freezing level and a measured rate. Two answers to one question is one
    /// answer too many, so this is now only the mapping from what is falling to
    /// how a surface feels it.
    /// Work out what a lip is actually experiencing, from measurements only.
    private func deriveSurfaceWeather(_ w: WeatherState) -> SurfaceWeather {
        var s = SurfaceWeather()

        // ---- SURFACE TEMPERATURE.
        //
        // A surface with open sky above it radiates into it and settles BELOW
        // air temperature; under cloud it radiates to the cloud base instead
        // and sits at the air. Wind is the other half of it: a breeze mixes
        // warm air down onto the lip and wipes the deficit out, which is why a
        // frost warning is for a clear CALM night rather than merely a cold
        // one. And in daylight the sun more than repays the loss.
        //
        // Every one of the three terms degrades to ZERO deficit when its
        // reading is missing, so an absent cloud report can only ever fail to
        // produce frost — never invent it.
        let clear = w.cover >= 0 ? max(0, 1 - min(1, w.cover / 100)) : 0
        let calm = max(0, 1 - w.wind / 20)
        let dark = max(0, min(1, -sunAlt / 6))
        s.surfaceTemp = w.temperature - 4.5 * clear * calm * dark

        // ---- DROP SIZE, from the measured fall speed. Atlas & Ulbrich give
        // v = 3.78 D^0.67 for raindrops at sea level; this is that inverted.
        // 2.5 m/s at a trace is a 0.5mm drizzle drop, 7.6 m/s in a 10mm/h
        // shower is a 2.8mm one, and those two do completely different things
        // to a surface.
        // Liquid only: the relation describes water drops, and a hailstone's
        // fall speed run through it would report a seven-millimetre "drop" that
        // beads and runs. A frozen hydrometeor has no liquid at all until it
        // melts, and then what runs is meltwater rather than the stone.
        let v = w.fallSpeed
        switch w.precipForm {
        case .rain, .drizzle, .freezingRain:
            s.dropDiameter = v > 0.25 ? pow(v / 3.78, 1 / 0.67) : 0
        default:
            s.dropDiameter = 0
        }

        // Below about 0.6mm the surface tension holding a drop to the lip beats
        // its own weight whatever else happens, so it cannot run — the measured
        // gate that separates drizzle from light rain without asking what the
        // hour was called. A frozen form runs only once the lip is warm enough
        // to melt what lands on it.
        let melts = w.isPrecipitating && s.dropDiameter <= 0 && s.surfaceTemp > 1
        s.canRun = (s.dropDiameter >= 0.6 && s.surfaceTemp > 0) || melts

        // ---- SHEETING. Discrete beads while the lip can shed what arrives;
        // a continuous film once it cannot. Rate does most of the work, and
        // large drops sheet sooner because each one already wets more than
        // surface tension can gather back into a bead.
        let rate = w.precipRate
        s.sheeting = s.canRun
            ? min(1, (rate / 7) * (0.55 + 0.45 * min(1, s.dropDiameter / 2.6)))
            : 0

        // ---- CONDENSATION. Dew point against the SURFACE, not humidity.
        let cross = w.dewPoint - s.surfaceTemp
        s.condensing = max(0, min(1, (cross + 0.4) / 1.6))

        // ---- WIND DRIVE. Which way, and how much of the water is thrown at
        // the lip rather than dropped onto it. A gust front does this before
        // the rain arrives; a squall does it while it is here.
        let rel = ((w.windDir - facingAz + 180 + 360)
                    .truncatingRemainder(dividingBy: 360)) - 180
        let side: Float = rel > 0 ? 1 : -1
        let steady = w.wind >= 14 ? min(1, (w.wind - 14) / 34) : 0
        s.driven = min(1, max(steady, w.gustFrontStrength)
                        * (w.morphology == .squally ? 1.4 : 1))
        s.drive = side * min(1, abs(rel) / 90) * s.driven

        // ---- SNOW HABIT. How the crystals stack once they land.
        switch w.snowHabit {
        case .dendrite:     s.snowBulk = 1.55   // open, branched, mostly air
        case .plate:        s.snowBulk = 1.25
        case .columnar:     s.snowBulk = 1.10
        case .needle:       s.snowBulk = 1.00
        case .wetAggregate: s.snowBulk = 0.75   // wet, heavy, slumps
        case .graupel:      s.snowBulk = 0.55   // rimed and near spherical
        case .none:         s.snowBulk = 1.00
        }
        return s
    }

    private func precipitationForm(_ w: WeatherState) -> DepositForm {
        switch w.precipForm {
        case .hail:         return .hail
        // Graupel and ice pellets bounce off and leave almost nothing, which is
        // what `sleet` means to a surface.
        case .graupel, .icePellets: return .sleet
        case .freezingRain:
            // Freezing rain is only freezing rain because the SURFACE is below
            // zero — that is the definition, not a property of the drop. The
            // same rain onto a lip the sun has been on all afternoon simply
            // runs off, and drawing a glaze there would be a glass sheet over a
            // warm dock.
            return surfaceWeather.freezing ? .freezingRain : .rain
        case .snow, .snowGrains:
            // Wet snow above freezing arrives as slush and behaves like sleet
            // on a surface: patchy, and gone in minutes.
            return (w.temperature > 1.5 && w.frozenFraction < 0.85) ? .sleet : .snow
        case .drizzle:      return .drizzle
        case .rain:
            // Same test again: what makes rain freezing is the lip, not the air
            // column. `temperature <= 0.3` used the air, which glazed a surface
            // the sun was still on and left a radiatively cooled one at +2
            // merely wet — both backwards.
            return surfaceWeather.freezing ? .freezingRain : .rain
        case .none:
            // Nothing falling. What the AIR alone does to a surface.
            //
            // This used to read `temperature < 0.5 && humidity > 78` for frost,
            // which is the classification-over-measurement mistake in miniature:
            // relative humidity is a ratio to a temperature-dependent saturation
            // pressure, so 80% RH means something completely different at -2°C
            // and at +28°C. It puts frost on a warm monsoon night and misses it
            // on a dry-feeling clear one at -3°C where the dew point is -4.
            //
            // The measured test is the DEW POINT against the SURFACE
            // temperature. Above that crossing the air gives up its water; below
            // it, it does not, whatever the humidity reads. Where the crossing
            // itself is below zero the vapour deposits as ice rather than
            // condensing as liquid, and that one comparison is the whole of the
            // difference between frost and dew.
            let s = surfaceWeather
            let wets = s.condensing > 0.02
            if wets && s.freezing { return .frost }        // includes rime in freezing fog
            // `obscuration` and not `fogginess`. `fogginess` is 0.7 x how small
            // the dew-point spread is, so it clears 0.55 at a spread of 1.4°C —
            // which is every clear calm night on which dew forms, at twelve
            // kilometres of visibility. It was reporting fog for the exact
            // conditions that produce the opposite of fog. `obscuration` is
            // built from measured VISIBILITY and can be contradicted by an
            // observer, which is what the word actually means.
            if w.obscuration == .fog || w.obscuration == .mist { return .fog }
            if wets { return .dew }
            if w.obscuration == .haze || w.aqi > 85 || w.smoke > 0.22 { return .dust }
            return .none
        }
    }

    /// Is this piece of furniture one the user lets weather mark?
    ///
    /// `Furniture.desktop` already filters at construction, so on a live desktop
    /// an opted-out dock is simply not in the list. This is the second half of
    /// the same answer, for the surfaces that do not come from there — the lock
    /// screen's clock, the offscreen harness's stand-ins — and for the window
    /// between the config changing and the host rebuilding the list. An opted-out
    /// surface is invisible to the weather in every respect: water falls through
    /// it rather than landing and then failing to show, because a drop that
    /// vanishes at an invisible line is more obviously wrong than a wet dock.
    private func marks(_ kind: Surface.Kind) -> Bool {
        switch kind {
        case .dock:             return Furniture.options.dock
        case .widget:           return Furniture.options.widgets
        case .menuBar:          return Furniture.options.menuBar
        case .clock, .loginBox: return true
        }
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
        // Furniture carries WATER and SNOW, and nothing else.
        //
        // The film model also grows frost, a clear glaze, grime and steam, and
        // each of those is defensible physics for a real ledge outdoors. The
        // dock is not a ledge outdoors: it is a piece of the user's interface,
        // and a rime of frost or a film of grime on it reads as the wallpaper
        // having gone wrong rather than as weather. Rain splashing off it and
        // snow settling on it read as weather immediately, because those are the
        // two things you actually watch happen to a windowsill.
        //
        // Cleared every step rather than never accumulated, so the decision
        // lives in one place and none of the physics below has to be unpicked or
        // kept in sync. `anyWater` reads `glaze` and `steam`, so zeroing them
        // here also stops them standing in for wetness they did not earn.
        for i in 0..<films.count {
            films[i].glaze = 0
            films[i].frost = 0
            films[i].grime = 0
            films[i].steam = 0
        }

        let sw = surfaceWeather
        let evap = w.evaporationRate
        let t = sw.surfaceTemp                           // the LIP's temperature
        let rate = w.precipRate                          // mm/h, measured
        let arrive = min(1.4, w.precipAmount / 3)        // arrival rate, 0..~1.4
        // Wind drives water onto and off a lip; a gust front throws it sideways.
        let windF = min(1.5, w.wind / 30)
        // Dirty air, from the three measures that actually track deposition.
        let dirty = min(1, max(w.aqi - 40, 0) / 220 + w.smoke * 0.6 + max(0, 1 - w.visibility / 9000) * 0.3)

        var meanGrime: Float = 0, meanSteam: Float = 0, counted = 0
        for i in 0..<films.count {
            // Opted out: still collision geometry, but nothing collects on it.
            // Cleared once rather than every frame, so turning the dock back on
            // starts it dry instead of restoring a week of weather.
            guard marks(surfaces[i].kind) else {
                if films[i].anyWater > 0 || films[i].snow > 0 || films[i].grime > 0 {
                    films[i] = SurfaceFilm()
                }
                continue
            }
            var f = films[i]

            // ---- what arrives
            switch form {
            case .rain:
                // How the water DISTRIBUTES is the whole difference between
                // light rain and heavy rain on a lip, and it is not a matter of
                // how much. Below the sheeting threshold surface tension gathers
                // the arriving water into discrete beads and the lip between
                // them stays comparatively dry; above it the beads have merged
                // and the whole edge carries a continuous film. Same
                // millimetres, two completely different pictures, and
                // `sheeting` is derived from the measured rate and the measured
                // drop size rather than from any threshold on the code.
                let soak = dt * (0.25 + arrive * 0.85)
                f.wet = min(1, f.wet + soak * (0.30 + sw.sheeting * 0.95))
                f.lip = min(1, f.lip + soak * (1.10 - sw.sheeting * 0.35)
                                     * (0.6 + windF * 0.5))
                // Only water that CAN run produces run-off. A lip covered in
                // drops too small to overcome their own surface tension has
                // nothing to shed however long it rains.
                if sw.canRun {
                    f.runoff = min(1, f.runoff + dt * (0.15 + arrive * 0.70)
                                                * (0.35 + sw.sheeting * 0.95))
                }
                f.grime = max(0, f.grime - dt * (0.10 + arrive * 0.35))
                // Strikes, so the lip flickers under rain the way it does under
                // sleet and hail. It decays at 3.2/s, so this is a level being
                // continuously topped up rather than a value that accumulates.
                f.impact = min(1, f.impact + dt * (0.20 + arrive * 1.0))

            case .drizzle:
                // 0.1-0.5mm drops, and two things follow from that size which
                // together are the whole of what drizzle looks like. They are
                // far too light to overcome the tension holding them, so they
                // never gather into beads and never run — `canRun` is false at
                // this diameter by measurement, not by name. And they arrive in
                // enormous numbers, so what they leave is perfectly even.
                //
                // An even sub-millimetre film scatters where a bead reflects,
                // which is why drizzle makes everything look FLAT: darker, but
                // with no highlight anywhere on it. It also soaks far more
                // thoroughly than its millimetres suggest, because none of it
                // runs off.
                f.wet = min(0.80, f.wet + dt * (0.08 + rate * 0.12))
                // Any meniscus that was there drains, and none is built.
                f.lip = max(0, f.lip - dt * 0.30)
                f.runoff = min(0.18, f.runoff + dt * 0.015)
                f.grime = max(0, f.grime - dt * 0.04)     // too gentle to wash

            case .freezingRain:
                // Liquid on arrival, solid within seconds of touching the lip.
                // How fast it sets is decided by how far BELOW zero the surface
                // is: at -0.5 the drop spreads and part of it runs before it
                // freezes, giving a thin uneven skin; by -6 it freezes
                // essentially where it lands. That is why the heaviest, clearest
                // glaze comes from an ice storm sitting just below freezing,
                // and it is a property of the surface, not of the sky.
                let below = min(1, max(0, -sw.surfaceTemp) / 6)
                f.glaze = min(1, f.glaze + dt * (0.035 + rate * 0.05) * (0.35 + 0.65 * below))
                // The fraction that has not set yet is still liquid, and it
                // still creeps to the lowest point — which is how a glaze grows
                // a fat lower lip and eventually an icicle.
                f.wet = min(0.50, f.wet + dt * 0.18 * (1 - below * 0.6))
                f.lip = min(0.42, f.lip + dt * 0.07 * (1 - below * 0.5))
                f.runoff = min(0.6, f.runoff + dt * 0.10 * (1 - below))
                f.grime = max(0, f.grime - dt * 0.06)

            case .sleet:
                // Ice pellets are frozen through. They do not deform and they do
                // not stick: they hit, rebound and skitter, so the visible
                // signature is the STRIKE and a shallow scatter of pellets that
                // came to rest along the lip — never a film. On a vertical face
                // there is nothing at all, which is why sleet leaves a
                // windscreen clear and the wiper trough full.
                f.impact = min(1, f.impact + dt * (0.7 + arrive * 1.6))
                // What settles stays LOOSE. Pellets do not bond to each other
                // the way crystals do, so wind rolls them off an exposed edge
                // about as fast as they arrive.
                f.snow = max(0, min(0.85, f.snow + dt * (rate * 0.05 - windF * 0.02)))
                f.snowSpan = max(0, min(1, f.snowSpan + dt * (0.10 - windF * 0.06)))
                // A pellet landing on a lip above freezing simply melts.
                if sw.surfaceTemp > 0 {
                    f.wet = min(0.45, f.wet + dt * min(1, sw.surfaceTemp / 4) * 0.14)
                }

            case .snow:
                // Depth is the snowfall times how loosely that crystal HABIT
                // stacks. A dendrite is mostly air and bulks up two or three
                // times deeper than the same water content of rimed graupel;
                // a wet aggregate slumps almost flat. This is why two nights
                // reported as the same centimetres look nothing alike, and
                // `snowBulk` comes from the measured habit rather than from the
                // word "snow".
                // Slow enough that the HABIT is visible in the depth and not
                // only in the texture. At the old rate a lip capped out in
                // eleven seconds whatever was falling, so open dendrites and
                // rimed graupel — which differ by a factor of three in how
                // deep they lie — both simply pinned at the ceiling and looked
                // identical. Now a moderate fall takes about a minute to cap
                // with dendrites and a little over two with graupel.
                let fall = (0.004 + w.snow * 0.012) * sw.snowBulk
                f.snow = min(3.4, f.snow + dt * fall)
                // The span fills in faster than the depth builds: a lip goes
                // white along its whole length within the first minute and then
                // keeps thickening for the rest of the storm. Wind takes it
                // back, and blowing snow is the measurement that says the wind
                // is actually moving what is already lying.
                let scour = windF * 0.02 + w.blowingSnow * 0.06
                f.snowSpan = max(0, min(1, f.snowSpan + dt * (0.05 + fall * 3) - dt * scour))
                f.wet = max(0, f.wet - dt * 0.05)
                f.grime = max(0, f.grime - dt * 0.03)

            case .hail:
                // A hailstone arrives at 14 m/s and leaves again with most of
                // it. The event is the strike and the rebound; almost none of
                // the mass stays, so what a lip looks like after a hailstorm is
                // wet — from meltwater — and not white.
                f.impact = min(1, f.impact + dt * (1.4 + arrive * 2.2))
                f.wet = min(1, f.wet + dt * (0.20 + arrive * 0.45))
                f.lip = min(0.55, f.lip + dt * 0.18)
                f.runoff = min(1, f.runoff + dt * 0.28)
                f.grime = max(0, f.grime - dt * 0.35)     // scoured, not washed

            case .fog:
                // The one hydrometeor with no momentum worth the name. Fog
                // droplets are tens of microns across and follow the air AROUND
                // an obstacle rather than hitting it, so a surface is wetted by
                // interception and by condensation instead of by impact — which
                // is exactly why fog wets undersides and sheltered faces as
                // thoroughly as the top, and rain never does.
                //
                // Density is the measured one, taken from visibility.
                let dens = max(w.obscurationDensity, w.fogginess)
                f.steam = min(1, f.steam + dt * (0.015 + dens * 0.11)
                                         * (0.35 + sw.condensing * 0.65))
                f.wet = min(0.65, f.wet + dt * sw.condensing * dens * 0.06)
                // Only once the film is thick enough does it gather and begin to
                // move. That is the moment fog stops looking like a bloom and
                // starts dripping off the eaves.
                if f.steam > 0.70 {
                    f.lip = min(0.50, f.lip + dt * 0.05)
                    f.runoff = min(0.5, f.runoff + dt * 0.04)
                }

            case .dew:
                // The same condensation as fog with clear air above it, and by
                // far the more common of the two. Nothing is falling and nothing
                // is suspended: the lip has simply radiated itself below the dew
                // point and the vapour touching it gives up its water. Evenly,
                // on every face, over hours — which is why a car roof is soaking
                // on a cloudless morning when nothing has fallen for a week, and
                // why the same night with a breeze or a cloud deck leaves it dry.
                f.steam = min(0.85, f.steam + dt * 0.010 * (0.30 + sw.condensing))
                f.wet = min(0.40, f.wet + dt * 0.004 * sw.condensing)

            case .frost:
                // Deposition: vapour straight to ice with no liquid in between.
                // It needs the lip below zero AND the dew point above the lip,
                // and the second condition is why a hard, dry, frost-free night
                // at -5°C is a perfectly ordinary thing.
                //
                // Growth follows how far past that crossing the air is, not how
                // cold it is. Crystals grow fastest a few degrees below zero and
                // slow right down in deep cold, where there is very little
                // vapour left in the air to deposit at all.
                let vigour = min(1, max(0, 1 - sw.surfaceTemp) / 5)
                           * max(0.15, 1 - max(0, -sw.surfaceTemp - 8) / 20)
                f.frost = min(1, f.frost + dt * 0.018 * sw.condensing * vigour)
                // A little liquid condenses on the warmest parts first and then
                // freezes, which is what welds the bloom to the surface.
                f.steam = min(0.35, f.steam + dt * sw.condensing * 0.015)

            case .dust:
                // Dry deposition. Nothing arrives out of the sky: particles
                // settle out of still air under their own weight and stick. The
                // rate follows the measured loading, and it is slow — days of
                // dirty air to build what one shower takes off in a minute.
                f.grime = min(1, f.grime + dt * dirty * 0.010)

            case .none:
                break
            }

            // Dirt settles whatever else is going on; rain is what removes it.
            // A glaze seals it under rather than washing it off, so freezing
            // rain is not on the washing list even though it is liquid on the
            // way down.
            if !form.washes {
                f.grime = min(1, f.grime + dt * dirty * 0.004)
            }

            // ---- what leaves
            //
            // Liquid goes by evaporation, on the same physical rate as the
            // pane, so the dock dries when the pane dries instead of on its own
            // invented timer.
            // Liquid goes by evaporation on the same physical rate as the pane's
            // film — 2.5x it, because a lip is a thin exposed edge with air on
            // three sides where a pane holds a flat film against glass. It was
            // 0.004 + evap * 0.09, which is NINE times the pane's rate: a
            // soaking dock went bone dry in twenty-five seconds while the
            // window beside it was still wet four minutes later, and the
            // comment above it claimed the two shared a timescale. On these
            // numbers a soaked lip takes about a minute and a half to clear in
            // bright dry air and the better part of half an hour in humid still
            // air, which is what water on a ledge actually does.
            let dry = dt * (0.0008 + evap * 0.025)
            if !form.deposits {
                f.wet = max(0, f.wet - dry)
                f.lip = max(0, f.lip - dry * 1.6)
                f.runoff = max(0, f.runoff - dt * 0.25)
            } else {
                f.runoff = max(0, f.runoff - dt * 0.12)
            }
            // Condensation is the same story. A surface below the dew point is
            // not evaporating — that is what being below the dew point means.
            if form != .fog && form != .dew {
                f.steam = max(0, f.steam - dt * (0.01 + evap * 0.12))
            }

            // Snow: melt is driven by the surface being above freezing, and it
            // eats the margins first, which is why a snow cap narrows before it
            // thins. Sublimation is much slower and happens even below zero.
            if f.snow > 0 && form != .snow {
                let melt = max(0, t) * 0.008 + max(0, w.uv - 1) * 0.0015
                let sublime = 0.0008 * (0.3 + evap)
                f.snow = max(0, f.snow - dt * (melt + sublime))
                // What melts becomes water on the lip.
                if melt > 0 { f.wet = min(1, f.wet + dt * melt * 1.6) }
                // The margins go first. An end of the cap has warm air on three
                // sides where the middle has it on one, so it retreats inward
                // roughly twice as fast as the crown thins — which is why a
                // snow cap NARROWS before it disappears rather than fading out
                // at full width. Sublimation is a surface loss and takes the
                // span with it too, just very slowly; that is the dry-air path,
                // and it works below freezing where melt does not.
                // Retreat is resisted by DEPTH. There is far more mass to
                // remove at the margin of a deep cap than a shallow one, so a
                // thick cap narrows slowly and then goes quickly once it has
                // thinned — and, crucially, cannot retreat to nothing while it
                // is still three centimetres deep in the middle, which a flat
                // rate let it do.
                let mass = max(0.5, f.snow)
                f.snowSpan = max(0, f.snowSpan - dt * (melt * 2.4 + sublime * 1.6) / mass)
                if f.snowSpan <= 0.001 { f.snow = 0 }
            }
            if f.snow <= 0.001 { f.snowSpan = 0 }
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
            counted += 1
            meanGrime += f.grime
            meanSteam += max(f.steam, f.wet * 0.3)
        }

        // Averaged over the surfaces that ACTUALLY collect, not over the array.
        // Dividing by the whole array would let an opted-out widget halve the
        // whole-screen grime the dock earned.
        let n = Float(max(1, counted))
        // The whole-pane terms follow the furniture rather than being invented
        // separately: they are the same air doing the same thing.
        grime = min(1, meanGrime / n)
        steam = min(1, meanSteam / n)

        // ---- what each thing physically IS.
        //
        // Everything above is the same physics for every surface, which is
        // correct — the same rain falls on all of them. What differs is the
        // OBJECT: how deep a film its top face can hold before water runs over,
        // and how fast it lets that water go. A widget is a broad flat panel and
        // genuinely ponds; a dock is a narrow rounded slab and cannot; the menu
        // bar is not a ledge at all, only an eave.
        //
        // Applied as a ceiling and a drain rather than by rewriting the physics
        // per kind, so there is exactly one model of how water behaves and the
        // material only says how much of it this object is able to keep.
        for i in 0..<films.count {
            let m = surfaces[i].material
            // Per-element control, on top of the material's own ceiling. A
            // widget the user has turned down is drier than an identical one
            // beside it, which the global switch could never express — it could
            // only say "widgets, all of them, yes or no".
            let own = max(0, min(1, surfaces[i].wetness))
            let cap = min(1, m.retention) * own
            films[i].lip = min(films[i].lip, cap)
            films[i].wet = min(films[i].wet, min(1, m.retention * 0.85) * own)
            if m.shed > 1 {
                // Sheds faster than the baseline: drain the excess.
                let drain = dt * 0.30 * (m.shed - 1)
                films[i].runoff = max(0, films[i].runoff - drain)
                films[i].lip    = max(0, films[i].lip - drain * 0.6)
            }
        }
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
            let m = s.material
            let supply = f.runoff * 0.8 + f.lip * 0.4 + f.steam * 0.15
            // A surface that sheds fast drips more often; one that beads hard
            // makes fewer, fatter drops, because it holds each one longer before
            // surface tension gives out.
            guard supply > 0.06,
                  rnd() < supply * dt * 3.5 * m.shed / (0.65 + m.beadiness * 0.55)
            else { continue }
            let r0 = SP * (0.30 + rnd() * 0.35) * (0.80 + m.beadiness * 0.45)
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
        // The measured picture first: `precipitationForm` asks it whether the
        // LIP is freezing, so it has to be current before the form is decided.
        surfaceWeather = deriveSurfaceWeather(w)
        form = precipitationForm(w)
        // Water driven in at a steep angle rather than dropped: the same
        // rainfall, thrown sideways, which is a completely different picture on
        // a vertical pane. A squall does it while the rain is here; a gust front
        // does it in the minutes BEFORE the rain arrives. Both are gated on
        // measured gusts and measured shower structure — never on CAPE, which
        // is the reading that once put lightning over a quiet evening.
        gustFront = w.morphology == .squally || w.gustFrontStrength > 0.25
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

        // Splashes are FURNITURE, not pane water — and this return was killing
        // them.
        //
        // `impactSpray` sits below here, and it is the one function built to
        // throw spray off a lip from the rain that is actually falling on it,
        // deliberately independent of whether a pane droplet happened to wander
        // past. Returning early skipped it, and cleared `drops` besides, so with
        // "water on the pane" switched off the dock and the widgets got no
        // splash at all — ever. Measured: 900 frames of 8 mm/h onto three
        // surfaces gave 573 splashes with the pane on and exactly 0 with it off.
        // The comment three lines above this one already says the two are
        // separate settings because they are separate effects; the code made one
        // depend on the other.
        //
        // So the pane state is still cleared — nothing should accumulate on
        // glass the user has turned off — but the function now CONTINUES when
        // there is furniture to rain on, and the pane-only accumulations below
        // are each gated on `paneOn` instead of on having returned.
        let furnitureOn = Furniture.options.furniture > 0.001
                       && !surfaces.isEmpty
                       && (Furniture.options.dock || Furniture.options.widgets
                           || Furniture.options.menuBar)
        if !paneOn {
            if !spots.isEmpty || !vortices.isEmpty || glassWet > 0 || poolDepth > 0 {
                spots.removeAll(keepingCapacity: true)
                vortices.removeAll(keepingCapacity: true)
                for i in 0..<trailCells.count { trailCells[i] = 0 }
                glassWet = 0; poolDepth = 0
            }
            if !furnitureOn {
                if !drops.isEmpty { drops.removeAll(keepingCapacity: true) }
                rasteriseGlass()
                return
            }
        }

        // wetness accumulates while raining and evaporates afterwards.
        // Pane-only: with the pane off this stays at zero, so the splash spray
        // running below leaves the glass itself untouched.
        if !paneOn {
            glassWet = 0
        } else if wet {
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
        // Spray thrown off the furniture's lips by the rainfall itself. It sits
        // inside the pane-water gate because spray is drawn as airborne
        // droplets and that is the layer the switch turns off; the lip's own
        // wetness, its beading and its strike flicker are furniture and carry
        // on regardless — see updateSurfaces and stampFurniture.
        impactSpray(dt: dt, w: w)

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
        if paneOn && wet && drops.count < Self.maxDrops && rnd() < seedRate * dt * 60 {
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
        if paneOn && form == .fog && drops.count < Self.maxDrops && rnd() < dt * 18 {
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
            //
            // `d.r > SP * 0.10` keeps spray from re-splashing. A splash puts its
            // fragments just above the lip with upward velocity, so every one of
            // them crosses the lip again on the way back down — without a size
            // floor each impact seeds a fresh generation of ever-smaller impacts
            // and the population runs away.
            if d.falling && d.splashLife == 0 && d.v > 4 && d.r > SP * 0.10 {
                var landed = false
                let prevY = d.y - d.v * dt
                for k in 0..<surfaces.count where surfaces[k].spans(d.x) && marks(surfaces[k].kind) {
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

    /// A stable pseudo-random number for a column. Deterministic, so a bead
    /// stays where it is from frame to frame instead of shimmering.
    @inline(__always)
    private func jitter(_ n: Float) -> Float {
        let s = sin(n * 12.9898 + 78.233) * 43758.5453
        return s - s.rounded(.down)
    }

    // MARK: Furniture, drawn
    //
    //  THE MISSING HALF. `films` held a complete per-surface record of wetness,
    //  beading, snow, glaze, frost and grime, updated every frame by
    //  `updateSurfaces` — and absolutely nothing read it. The only path from the
    //  simulation to the shader is `glassCells`, and the one place that wrote
    //  furniture into it was the snow block, gated on a dictionary that was
    //  deliberately left empty. So the physics ran correctly and invisibly for
    //  the entire life of the feature: the dock got wet in memory only.
    //
    //  Where it draws matters as much as that it draws. The dock, the menu bar
    //  and a widget all render OVER the wallpaper, so anything stamped inside
    //  their rect is hidden by the real thing. The visible surface is the pane
    //  immediately outside them: the band of cells above a top edge, where the
    //  meniscus stands and the sheen spreads, and the band below a bottom edge,
    //  where fog condenses on the underside and drips hang.

    /// Cell kinds written into `glassCells.y`. The pane's own water owns 0-5;
    /// the furniture's deposits are 6 and up, and each is a distinct MATERIAL
    /// in the presentation pass rather than one wetness at several strengths.
    private enum Deposit {
        static let bead: Float = 1      // pane: a drop, shaded as a bead
        static let film: Float = 2      // pane: a wet track
        static let lipBead: Float = 12  // a bead standing on a soaked lip
        static let snow: Float = 6
        static let sheen: Float = 7     // liquid water on a lip: dark, glossy
        static let glaze: Float = 8     // clear ice
        static let frost: Float = 9     // crystalline bloom
        static let grime: Float = 10    // dry deposition
        static let matte: Float = 11    // drizzle's flat film
        static let bloom: Float = 13    // condensation: scattering, not glossy
    }

    /// Draw what has collected on each piece of furniture into the cells around
    /// it. Layered in physical order, later passes standing in front of earlier
    /// ones: dirt, then water, then ice, then frost, then snow on top of the lot.
    private func stampFurniture() {
        guard films.count == surfaces.count, !films.isEmpty,
              !glassCells.isEmpty, SP > 0 else { return }
        let strength = max(0, min(1, Furniture.options.furniture))
        guard strength > 0.003 else { return }
        let sw = surfaceWeather

        // WHY THIS DOES NOT WRITE WHOLE CELLS ANY MORE.
        //
        // Every deposit here used to be stamped as `glassCells[k] = ...`: a
        // whole cell, at full strength, for every cell from one end of the
        // furniture to the other, ending dead on a cell boundary at each end
        // and on a cell boundary at the top. That is the description of a
        // RECTANGLE, and it is what the user was looking at — the marks read as
        // an outlined box drawn on the wallpaper rather than as water lying on
        // a surface. Three things were doing it, and all three are fixed here:
        //
        //   1. THE ENDS. The band started and stopped at whole cells, at full
        //      amplitude. Now the end cells carry the fraction of themselves
        //      the furniture actually covers, and the outermost cell and a half
        //      is tapered on top of that, so the run of water thins out where
        //      the panel does instead of being guillotined.
        //   2. THE TOP. `reach` was an integer number of cells, so the upper
        //      edge of the band was a ruled line along a cell boundary. It is
        //      fractional now, jittered per column, and the topmost cell
        //      carries how much of ITSELF is wet in `by` — which the
        //      presentation pass uses to dissolve the deposit inside that cell.
        //      That is what the subdivision is for.
        //   3. THE OVERWRITE. `=` meant the last layer to run replaced whatever
        //      was under it, with a hard seam wherever two deposits met. A
        //      deposit now only takes a cell it is stronger in, and takes the
        //      louder of the two amplitudes, so the layers meet by blending.
        //
        // `by` is the fraction of the cell, measured from its TOP, that is NOT
        // covered by this deposit. Zero means the whole cell, which is what
        // every caller that does not care passes.

        @inline(__always)
        func put(_ cx: Int, _ cy: Int, _ v: Float, _ kind: Float,
                 _ bx: Float = 0, _ by: Float = 0) {
            guard cx >= 0, cx < cols, cy >= 0, cy < rows else { return }
            let a = min(1, v * strength)
            guard a > 0.02 else { return }
            let k = cy * cols + cx
            let old = glassCells[k]
            // Pane water (kinds 1-5) is atmosphere and always yields to the
            // furniture; between two furniture deposits the stronger one wins
            // the cell, but it inherits the louder amplitude so the join is a
            // blend rather than a step.
            if old.x > 0.02, old.y >= 6, old.x > a * 1.15 { return }
            glassCells[k] = SIMD4<Float>(max(a, old.y >= 6 ? old.x * 0.55 : 0),
                                         kind, bx, by)
        }

        for i in 0..<surfaces.count {
            let s = surfaces[i]
            guard marks(s.kind) else { continue }
            let f = films[i]

            let c0 = max(0, Int(s.left / SP))
            let c1 = min(cols - 1, Int((s.right - 0.001) / SP))
            guard c0 <= c1 else { continue }
            let span = Float(c1 - c0 + 1)

            // How much of cell `cx` the furniture actually spans, and how far
            // in from the ends it is. Furniture does not land on cell
            // boundaries and the marks must not pretend it does.
            let leftC = s.left / SP, rightC = s.right / SP
            @inline(__always)
            func endWeight(_ cx: Int) -> Float {
                let covered = min(Float(cx) + 1, rightC) - max(Float(cx), leftC)
                let cover = max(0, min(1, covered))
                // A run of water thins toward the corner of a panel rather than
                // reaching the very end at full depth: the meniscus has less to
                // hold on to there. A cell and a half of taper.
                let inFromEnd = min(Float(cx) + 0.5 - leftC, rightC - Float(cx) - 0.5)
                let soft = max(0, min(1, inFromEnd / 1.5))
                return cover * (0.42 + 0.58 * soft)
            }

            // The cell the top edge falls in, and where inside it the edge
            // actually is. The furniture covers everything below `lipFrac`, so
            // that part of the cell is hidden whatever we draw there.
            let lipF = s.top / SP
            let lipRow = Int(lipF)

            // ---- dirt. Underneath everything, and the widest band, because
            // dry deposition settles rather than being thrown at an edge.
            if f.grime > 0.05 {
                for cx in c0...c1 {
                    let e = endWeight(cx)
                    guard e > 0.02 else { continue }
                    let g = f.grime * e * (0.55 + 0.45 * jitter(Float(cx) * 5.1 + Float(i)))
                    put(cx, lipRow, g * 0.7, Deposit.grime)
                    // Dry deposition has no meniscus to hold an edge, so the
                    // upper limit of the band is the raggedest thing here.
                    let up = 0.30 + 0.55 * jitter(Float(cx) * 2.7 + Float(i) * 1.9)
                    put(cx, lipRow - 1, g * 0.32, Deposit.grime, 0, 1 - up)
                }
            }

            // ---- liquid water: the sheen, the beading and the runs.
            //
            // Thickest AT the edge and thinning upward — the corner holds the
            // meniscus and the film spreads away from it. Getting this the
            // other way round would put the water in a halo floating above the
            // dock with a dry line along the lip itself.
            let filmAmt = min(1, max(f.wet, f.steam))
            let lipAmt = min(1, f.lip)
            let condensing = (form == .fog || form == .dew)
            if filmAmt > 0.03 || lipAmt > 0.03 {
                // Matte or glossy is decided by whether the water that arrived
                // is ABLE to gather into beads — a measured drop diameter
                // against surface tension — rather than by which word the hour
                // was given. Drizzle is matte because its drops are 0.3mm; so
                // is the first minute of a very light shower, and so is dew,
                // and all three look the same for the same reason.
                let matte = form == .dew || form == .drizzle
                         || (form.impacts && !sw.canRun)
                // How far the film reaches up from the edge. Wind-driven rain is
                // thrown AT the lip rather than dropped on it, so it wets
                // considerably further up the face than the same rainfall
                // falling straight down.
                //
                // The drive term is added OUTSIDE the saturating part, not
                // inside it. Inside, `min(3.9, lip*1.7 + film*1.3 + driven*1.6)`
                // was already at 3.0 from the film alone the moment it started
                // raining, and Int() then rounded 3.0 and 3.9 to the same
                // number of cells — a fifty-kilometre-an-hour squall and a dead
                // calm drew a byte-identical band.
                //
                // FRACTIONAL, not a whole number of cells. Rounding it was the
                // second half of why the marks read as a drawn rectangle: every
                // column reached the same integer height, so the top of the
                // band was a ruled line lying exactly along a cell boundary.
                // Water does not have a straight upper edge, and the engine can
                // already draw a partial cell.
                let reach = 1 + min(2.4, lipAmt * 1.4 + filmAmt * 1.0)
                          + sw.driven * 2.4
                for cx in c0...c1 {
                    let endW = endWeight(cx)
                    guard endW > 0.02 else { continue }
                    let ph = jitter(Float(cx) * 1.37 + Float(i) * 7.13)
                    let ph2 = jitter(Float(cx) * 3.71 + Float(i) * 2.90 + 11)
                    // Roughly half the lip carries a fat bead and the rest a
                    // thin fillet, each swelling and draining on its own slow
                    // cycle. A uniform row of identical beads reads as a dashed
                    // line; water does not do that.
                    let swell = 0.30 + 0.70
                        * (0.5 + 0.5 * sin(simSec * (0.35 + ph * 0.85) + ph2 * 6.2832))
                    let fat = !matte && ph > 0.44
                    let bead = fat ? lipAmt * swell : lipAmt * 0.20

                    // A run: a column where the lip has taken more than it can
                    // hold. Only where the form leaves water that CAN run, only
                    // where there is runoff feeding it, and only on a few
                    // columns — a rivulet is a local failure of the meniscus,
                    // not something the whole edge does at once.
                    let runs = form.runs && f.runoff > 0.05 && ph2 > 0.78
                    let runLen = runs ? 2 + Int(min(4, f.runoff * 5)) : 0

                    // A lip is not uniformly wet along its length. This is the
                    // difference between a band of water and a ruled line.
                    var patch = 0.62 + 0.38 * jitter(Float(cx) * 0.83 + Float(i) * 4.1)

                    // EXPOSURE. Wind-driven rain does not wet an edge evenly: it
                    // is thrown at the windward end and the sheltered end stays
                    // comparatively dry. In still air there is no windward end
                    // and the whole lip is wetted alike, which is why this term
                    // is scaled by `driven` and vanishes with it rather than
                    // always asserting a gradient.
                    patch *= endW

                    // Every column reaches its own height, by a good margin —
                    // a third either way. This is the difference between a band
                    // of water and a line ruled along the top of the dock.
                    var reachC = reach * (0.68 + 0.64 * jitter(Float(cx) * 6.1 + Float(i) * 2.3))
                    if sw.driven > 0.05 && span > 1 {
                        let along = Float(cx - c0) / (span - 1)
                        let windward = sw.drive > 0 ? along : 1 - along
                        let expo = 1 - sw.driven * 0.70 * (1 - windward)
                        patch *= expo
                        reachC *= expo
                    }
                    reachC = max(0.45, reachC)

                    for k in 0..<max(Int(reachC.rounded(.up)), runLen) {
                        let cy = lipRow - k
                        guard cy >= 0 else { break }
                        // Distance from the real edge, for the strength falloff.
                        let up = max(0, lipF - Float(cy + 1))
                        // How much of THIS cell the water actually covers,
                        // measured up from the lip. The remainder is handed to
                        // the shader in `by` so the topmost cell of the band
                        // dissolves inside itself instead of ending on the
                        // boundary — which is what the subdivision is for.
                        // Measured from the furniture's TRUE top edge, not from
                        // the cell boundary nearest it.
                        //
                        // `lipF` is the edge in cell units and only its integer
                        // part was ever read — the fractional part was computed
                        // and thrown away, which is the third bug class in
                        // HANDOFF.md. So the band's BASE snapped to whichever
                        // cell boundary happened to be closest, up to a whole
                        // cell from where the widget actually is. Its top edge
                        // feathered beautifully and the whole thing sat in the
                        // wrong place: at production density that is 40-odd
                        // backing pixels of offset against a crisp widget
                        // corner, which is exactly why the effects did not line
                        // up with the furniture.
                        //
                        // Now the band is the interval [lipF - reach, lipF]
                        // intersected with this cell, so its base lands on the
                        // real edge to sub-pixel precision and `by` — the bare
                        // fraction the shader feathers from — falls out of the
                        // same arithmetic.
                        let bandTop = lipF - reachC
                        let cellTop = Float(cy), cellBot = Float(cy + 1)
                        let lo = max(cellTop, bandTop)
                        let hi = min(cellBot, lipF)
                        let cover = max(0, hi - lo)
                        let byFrac = max(0, min(1, lo - cellTop))
                        // Strongest AT the edge, thinning upward, and it has to
                        // stay legible for the two or three cells it reaches or
                        // the whole band collapses back to the single ruled row
                        // a square falloff gives.
                        let fall = max(0, 1 - (up + 0.5) / reachC)
                        let sheen = filmAmt * patch * fall * (0.60 + 0.40 * fall)
                        let runV = k < runLen
                            ? f.runoff * (1 - up / Float(max(runLen, 1))) * 0.85 : 0

                        // Condensation SCATTERS. A surface carrying micron-scale
                        // droplets is optically rough, so it goes pale and hazy
                        // instead of dark and glossy — breath on a window, not
                        // rain on a window. It is the only wet material here
                        // that lightens what it covers, and that is not a
                        // stylistic choice: darkening was making dew literally
                        // invisible on the clear night that is the only time it
                        // forms, because there is nothing to darken.
                        //
                        // `fat` is already false whenever `matte` is, so dew
                        // never reaches the bead branches above and fog only
                        // does once its film has genuinely gathered.
                        if condensing {
                            put(cx, cy, min(0.95, sheen * 0.75 + 0.20 * endW),
                                Deposit.bloom, 0, byFrac)
                            continue
                        }
                        if matte {
                            put(cx, cy, sheen * 0.85, Deposit.matte, 0, byFrac)
                            continue
                        }
                        // The meniscus sits IN the lip row and nowhere else, so
                        // a fat column is a bead there whatever the film around
                        // it is doing. Comparing the two as though they competed
                        // meant the sheen — which is pinned near 1 the moment it
                        // starts raining — won every column and the beading
                        // never appeared at all.
                        if k == 0 && fat && bead > 0.15 {
                            // Where the cell sits inside the bead, so the shader
                            // can shade it out of whole cells: a little left of
                            // centre and above it, which is where the highlight
                            // of a hanging drop lives.
                            put(cx, cy, min(0.95, 0.40 + bead * 0.55), Deposit.lipBead,
                                (ph - 0.5) * 0.9, -0.28)
                        } else if k == 1 && fat && bead > 0.55 {
                            // A bead big enough to stand proud of the edge
                            // occupies the cell above it too.
                            put(cx, cy, min(0.8, 0.25 + bead * 0.45), Deposit.lipBead,
                                (ph - 0.5) * 0.7, 0.45)
                        } else if runV > sheen {
                            put(cx, cy, runV * 0.85, Deposit.film, 0, byFrac)
                        } else {
                            put(cx, cy, sheen * 0.88, Deposit.sheen, 0, byFrac)
                        }
                    }
                }
            }

            // ---- clear ice. Freezing rain glazes: it does not run and it does
            // not bead, so it is a smooth even skin over the whole lip that
            // simply thickens.
            if f.glaze > 0.04 {
                // Fractional for the same reason the film's reach is: a glaze
                // is smooth, but its upper limit is where the runback froze,
                // and that is not a cell boundary.
                let depth = 1 + min(2, f.glaze * 2.4)
                for cx in c0...c1 {
                    let e = endWeight(cx)
                    guard e > 0.02 else { continue }
                    let d = depth * (0.82 + 0.36 * jitter(Float(cx) * 4.4 + Float(i)))
                    for k in 0..<Int(d.rounded(.up)) {
                        let cy = lipRow - k
                        guard cy >= 0 else { break }
                        let fall = 1 - Float(k) / (d + 1)
                        put(cx, cy, min(0.95, f.glaze * e * fall * 0.95), Deposit.glaze,
                            0, 1 - max(0, min(1, d - Float(k))))
                    }
                }
            }

            // ---- frost. Grows OUT OF THE EDGES: a corner radiates to more of
            // the sky than the middle of a face does, so it reaches sub-zero
            // first and the bloom starts there and creeps inward.
            if f.frost > 0.04 {
                let bloom = max(1.5, span * 0.35 * min(1, 0.3 + f.frost))
                let depth = 1 + min(2, f.frost * 2.6)
                for cx in c0...c1 {
                    let e = endWeight(cx)
                    let fromEnd = Float(min(cx - c0, c1 - cx))
                    let edgeness = max(0, 1 - fromEnd / bloom)
                    let crystal = 0.55 + 0.45 * jitter(Float(cx) * 9.7 + Float(i) * 3.3)
                    let a = f.frost * e * (0.25 + 0.75 * edgeness * edgeness) * crystal
                    guard a > 0.05 else { continue }
                    // Crystals grow to their own height. A bloom with a level
                    // top is paint, not frost.
                    let d = depth * (0.70 + 0.60 * crystal)
                    for k in 0..<Int(d.rounded(.up)) {
                        let cy = lipRow - k
                        guard cy >= 0 else { break }
                        put(cx, cy, a * (1 - Float(k) / (d + 1)), Deposit.frost,
                            0, 1 - max(0, min(1, d - Float(k))))
                    }
                }
            }

            // ---- snow, on top of everything, because it lies on top of
            // everything. Depth is `f.snow` in cells; `f.snowSpan` is how much
            // of the lip it still covers, and melt takes the span back from the
            // margins, so a thawing cap narrows toward the middle rather than
            // fading out at full width.
            if f.snow > 0.05 && f.snowSpan > 0.02 {
                // Crystals BOND to each other and pellets do not, and that
                // single difference decides the shape of what is lying there. A
                // snow cap is a coherent drift: it holds a rounded crown, it
                // overhangs the edge, and it is continuous. Ice pellets are
                // loose ball bearings that find their own level — a shallow,
                // flat, patchy scatter with bare gaps in it, which is what sleet
                // on a ledge actually looks like.
                let loose = (form == .sleet)
                let mid = (Float(c0) + Float(c1) + 1) * 0.5
                let half = span * 0.5 * f.snowSpan
                // How rough the top of the drift is. Open dendrites pile into an
                // uneven crown; rimed graupel and wet aggregates settle nearly
                // level, and pellets are level by definition.
                let rough = loose ? 0.55 : 0.10 + 0.28 * max(0, sw.snowBulk - 0.7)
                for cx in c0...c1 {
                    let off = abs(Float(cx) + 0.5 - mid)
                    guard off <= half else { continue }
                    let g = jitter(Float(cx) * 2.3 + Float(i) * 5.7)
                    // Loose pellets do not span gaps, so some columns simply
                    // have none. A bonded cap is continuous and never does this.
                    if loose && g > 0.45 + f.snow * 0.5 { continue }
                    // A drift is deepest over the middle of what is left and
                    // tapers to nothing at the retreating ends; a scatter is
                    // flat right up to where it stops.
                    let t = half <= 0.5 ? 0 : off / half
                    let prof = loose ? 1 : sqrt(max(0, 1 - t * t))
                    let deep = f.snow * prof * (1 - rough * g)
                    guard deep > 0.12 else { continue }
                    let rows_ = Int(deep.rounded(.up))
                    for k in 0..<rows_ {
                        let cy = lipRow - k
                        guard cy >= 0 else { break }
                        // The top layer of the cap is a partial cell, so it
                        // fades rather than ending on a hard step.
                        let cover = min(1, deep - Float(k))
                        put(cx, cy, 0.35 + 0.60 * cover, Deposit.snow)
                    }
                }
            }

            // ---- STRIKES. What is arriving, at the instant it arrives.
            //
            // `impact` decays at 3.2/s, so this is a flicker of individual
            // events rather than a level: a scatter of bright points along the
            // lip that is never the same two frames running. It is the only
            // thing in here that shows the RATE rather than the accumulation,
            // and for hail it is very nearly the whole of the effect — a
            // hailstorm leaves almost nothing behind but you can see every
            // stone that hits.
            if f.impact > 0.04 && form.impacts {
                // Hail strikes are far fewer and far harder than rain's.
                let heavy = (form == .hail || form == .sleet)
                let live = f.impact * (heavy ? 1.0 : 0.55)
                let churn = simSec * (heavy ? 9 : 16)
                for cx in c0...c1 {
                    // A different set of columns every few frames.
                    let g = jitter(Float(cx) * 1.9 + Float(i) * 3.1 + churn.rounded(.down))
                    guard g > 1 - live * (heavy ? 0.30 : 0.22) else { continue }
                    let cy = lipRow - (g > 0.94 ? 1 : 0)
                    guard cy >= 0 else { continue }
                    // A strike is a burst of spray seen end-on: bright, small,
                    // and gone. Drawn as a bead with the highlight dead centre
                    // so it reads as a flash rather than as a hanging drop.
                    put(cx, cy, min(0.95, 0.45 + live * 0.5), Deposit.lipBead, 0, -0.05)
                }
            }

            // ---- the UNDERSIDE.
            //
            // Condensation is the only way water reaches a face that points at
            // the ground, and it is the sharpest test of whether this whole
            // model is doing physics or decoration: rain can NEVER wet an
            // underside however hard it falls, and fog and dew always do, at
            // exactly the same strength as they wet the top. An engine that
            // treats deposits as one wetness at several strengths cannot express
            // that difference at all.
            guard s.hasUnderside(screenHeight: H) else { continue }
            let under = max(f.steam, condensing ? f.wet * 0.6 : 0)
            let hang = max(under, f.glaze * 0.5)
            guard hang > 0.05 else { continue }
            let botRow = Int(s.bottom / SP)
            let depth = hang > 0.45 ? 2 : 1
            for cx in c0...c1 {
                let ph = jitter(Float(cx) * 4.9 + Float(i) * 1.7)
                for k in 0..<depth {
                    let cy = botRow + k
                    guard cy < rows else { break }
                    let fall = 1 - Float(k) / Float(depth + 1)
                    // A drip line is beaded, not continuous: the film gathers
                    // into pendant drops at intervals along the lip.
                    let pendant = ph > 0.72 && k == 0
                    if f.glaze > 0.25 && f.glaze * 0.5 >= under {
                        put(cx, cy, f.glaze * fall * 0.8, Deposit.glaze)
                    } else if pendant && under > 0.55 {
                        // A pendant drop only forms once the film is thick
                        // enough to gather. Below that the underside carries the
                        // same scattering bloom as the top face — which is the
                        // point: condensation does not care which way a face
                        // points, and nothing else here can say that.
                        put(cx, cy, min(0.85, 0.35 + under * 0.55), Deposit.lipBead,
                            (ph - 0.5) * 0.8, -0.20)
                    } else {
                        put(cx, cy, min(0.92, under * fall * 0.75 + 0.18), Deposit.bloom)
                    }
                }
            }
        }
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

        // Everything lying on the furniture. After the pane's own film and pool
        // — what is on the dock is in front of what is on the glass — and
        // before the droplets, so spray can still land over the top of it.
        stampFurniture()

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
            // Spray thrown off a lip is not ambient pane wetness and must not be
            // stamped like it.
            //
            // Everything else here deliberately changes the MATERIAL of a cell
            // rather than being drawn on top of it — that is what stopped the
            // pane reading as bright confetti, and it is right for condensation,
            // for tracks and for beads, all of which are slow and everywhere. A
            // splash is the opposite of all three: brief, local, and the entire
            // point is that you SEE it. Stamped at a fragment's own radius,
            // which is 0.08 to 0.30 of a cell, each one marked a fraction of one
            // cell fractionally wetter and was invisible. Measured: 617 splashes
            // in a 900-frame downpour, not one of them visible above a lip.
            //
            // So spray gets a floor on its footprint — nearly a whole cell, so it
            // marks the mosaic it is made of — and close to full strength, which
            // it can afford precisely because it lasts under a second and only
            // ever exists directly above a surface's top edge. Ambient water is
            // untouched, so the confetti that the material approach was written
            // to remove cannot come back.
            if d.splashLife > 0 {
                // Kind 20: spray, which the presentation pass refines further
                // than anything else and gives relief of its own. A splash is
                // the one water element small enough that the coarse grid
                // destroys it outright, and the engine already has the mechanism
                // for exactly that — see the DETAIL note in Scene.metal.
                stamp(x: d.x, y: d.y, r: max(d.r * 1.15, SP * 0.85),
                      kind: 20,
                      strength: min(1, 0.55 + 0.45 * intensity),
                      bead: true)
                continue
            }
            stamp(x: d.x, y: d.y, r: d.r * 1.15,
                  kind: mature ? 1 : 2,
                  strength: (mature ? 0.85 : 0.45) * intensity,
                  bead: mature)
        }
    }
}
