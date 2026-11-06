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
    /// The surface whose top edge this drop is running along, or -1. Water
    /// running down a pane that meets something stuck to it does not vanish:
    /// it gathers on the edge, runs along it and falls off the end.
    var ride: Int = -1
    var rideDir: Float = 0
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
/// One fallen leaf lying on a top edge: where along it (0 the left end, 1 the
/// right), its fresh colour (0..1, crimson to gold) and how many days it has
/// lain — it browns as it ages.
struct LyingLeaf: Codable {
    var u: Float
    var hue: Float
    var age: Float
}

struct SurfaceFilm: Codable {
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

    /// The fallen leaves lying on the lip, EACH WHERE IT LANDED: a leaf that
    /// came down near the left end lies near the left end, the wind walks it
    /// along one cell at a time, and it is still there after a restart
    /// (FurnitureMemory). Asked for 6 Nov 2026: "have some memory of element
    /// placement". Not this struct's own coding.
    var lying: [LyingLeaf] = []
    /// How many cells long the lip is, kept by the simulation, so `leaves`
    /// can say how covered it is.
    var leafRoom: Float = 10
    /// How covered the lip is with leaves, 0..1.
    var leaves: Float { min(1, Float(lying.count) / max(3, leafRoom)) }
    /// How long the pile has lain, on average, in days.
    var leafAge: Float {
        lying.isEmpty ? 0 : lying.reduce(0) { $0 + $1.age } / Float(lying.count)
    }

    /// Everything wet added up — what the shader needs for one band.
    var anyWater: Float { max(max(wet, lip), max(glaze, steam)) }

    enum CodingKeys: String, CodingKey {
        case wet, lip, snow, snowSpan, glaze, frost, grime, steam, impact, runoff
    }
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
    /// `stop` is the row a streak LANDED on — the top edge of the dock or a
    /// widget — and `resume` the row below it where the rain picks up again;
    /// between the two it is hidden. Infinity while it is falling free.
    private var streaks: [(c: Float, y: Float, len: Float, v: Float,
                           slope: Float, wob: Float, ph: Float, hops: Float,
                           stop: Float, resume: Float, depth: Float)] = []

    /// Whether a point (pixels) is sheltered: under a piece of furniture, down
    /// to a little below it. Rain is not born there.
    /// Whether a point (pixels) lies inside any piece of furniture's outline.
    private func insideFurniture(_ x: Float, _ y: Float) -> Bool {
        for s in surfaces where s.kind != .menuBar
            && x >= s.left && x <= s.right && y >= s.top && y <= s.bottom { return true }
        return false
    }

    private func shelterTop(atX x: Float, below y: Float) -> Float? {
        var best: Float? = nil
        for s in surfaces where s.kind != .menuBar && x >= s.left && x <= s.right
            && y > s.top && y < s.bottom + s.h * 0.6 + SP * 2 {
            if best == nil || s.top > best! { best = s.top }
        }
        return best
    }

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
        // Where the falling rain is, by screen third and top/bottom half — so
        // "it only rains in one corner" is a number, not a screenshot.
        var zones = [Int](repeating: 0, count: 6)
        if cols > 0, rows > 0 {
            for (i, v) in streakCells.enumerated() where v > 0.01 {
                let cx = i % cols, cy = i / cols
                zones[min(2, cx * 3 / cols) + (cy * 2 / rows) * 3] += 1
            }
        }
        let zoneStr = "rainZones top \(zones[0])/\(zones[1])/\(zones[2]) bottom \(zones[3])/\(zones[4])/\(zones[5])"
        let wet = trailCells.filter { $0 > 0.15 }.count
        let mean = trailCells.isEmpty ? 0 : trailCells.reduce(0, +) / Float(trailCells.count)
        let peak = trailCells.max() ?? 0
        let fMin = precipField.min() ?? 0
        let fMean = precipField.isEmpty ? 0 : precipField.reduce(0, +) / Float(precipField.count)
        return String(format: "meteors=%d rate=%.1f/h | T=%.0f RH=%.0f Td=%.1f wind=%.0f uv=%.1f evap=%.3f vpd=%.2f | surfaces=%d splashes=%d streaks=%d lit=%d drops=%d | film mean=%.3f peak=%.2f wet>0.15=%d/%d "
                            + "| pool=%.2f spots=%d grid=%dx%d | field min=%.2f mean=%.2f dryCols=%d",
                      shootCount, meteorRatePerHour,
                      lastWeather.temperature, lastWeather.humidity, lastWeather.dewPoint,
                      lastWeather.wind, lastWeather.uv,
                      lastWeather.evaporationRate, lastWeather.vapourPressureDeficit,
                      surfaces.count, splashCount, streaks.count, lit, drops.count, mean, peak, wet, trailCells.count,
                      poolDepth, spots.count, cols, rows,
                      fMin, fMean, precipField.filter { $0 < 0.05 }.count)
            + " | " + zoneStr
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

    /// The pointer dragging on the desktop, in this surface's pixels — set by
    /// the renderer each frame. See Cursor.swift.
    var cursor = Cursor.State(x: -1e5, y: -1e5, vx: 0, vy: 0, drag: 0)

    /// The wind ACROSS the screen, km/h, positive blowing toward the right.
    ///
    /// One definition for every element, because they used to disagree. The sky
    /// maps azimuth increasing to the right (`astroXY`), and wind is reported as
    /// the direction it comes FROM, so it carries things toward windDir + 180:
    /// a westerly seen facing south moves everything LEFT. The rain's slant had
    /// that the wrong way round, and the water on the glass ignored direction
    /// altogether and always ran right. Everything that the wind moves — rain,
    /// snow, spray, drips, water on the glass, the cloud edge, where showers
    /// fall — reads this.
    static func crossWind(_ w: WeatherState, facingAz: Float) -> Float {
        let rel = (w.windDir + 180 - facingAz) * .pi / 180
        return w.wind * sin(rel)
    }
    private var crossWind: Float { Self.crossWind(lastWeather, facingAz: facingAz) }
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

    /// Things in the air that are not water: snow knocked off something that
    /// moved, falling as clumps (shake()), and in the fall, LEAVES — the same
    /// free-flying bits, with a flutter, a slow fall and a colour.
    private struct Clump {
        var x, y, vx, vy, r: Float
        var leaf = false
        var hue: Float = 0          // leaves: crimson .. orange .. gold
        var phase: Float = 0        // leaves: where in its flutter
        var age: Float = 0          // leaves: days lain, before it was lifted
    }
    private var clumps: [Clump] = []
    /// Leaves lying along the bottom of the screen, per column, 0..1, and how
    /// many days they have lain.
    private var groundLeaves: [Float] = []
    private var groundLeafAge: [Float] = []
    /// The wind's gusts, which is what actually strips a tree: leaves come
    /// down in flurries with the gusts and hardly at all between them.
    private var gustLeft: Float = 0          // seconds of the current gust
    private var nextGust: Float = 8
    /// How much the trees shed today, set each step (leafClearPerDay uses it).
    private var leafSeasonNow: Float = 0
    /// How fast lying leaves clear, in cover per day: barely in the season —
    /// they pile up — then over a couple of weeks once the trees are bare.
    private var leafClearPerDay: Float { leafSeasonNow > 0.15 ? 0.01 : 0.07 }
    private var leafClock: Float = 0
    /// Scratch for drawing: how many leaves are already in each cell.
    private var leafStack: [UInt8] = []

    // MARK: Paths
    //
    // Where the pointer goes most is worn (Wear): snow, water and frost thin
    // there and lie thicker at its shoulders, and leaves are scuffed aside
    // into the quiet spots on either side. "The places we go most dry out
    // faster, like it creates paths."

    /// Wear at a point in this surface's pixels, 0..1. Set by the renderer.
    var wearSampler: ((Float, Float) -> Float)?
    /// Per surface, per column from its first: how worn the top is there.
    private var surfaceWear: [[Float]] = []
    private var groundWear: [Float] = []

    /// Re-read the wear under the furniture. Every ten seconds is plenty:
    /// a path takes days to wear in.
    private func refreshWear() {
        guard let w = wearSampler, SP > 0 else { surfaceWear = []; groundWear = []; return }
        surfaceWear = surfaces.map { s in
            let c0 = Int(s.left / SP), c1 = max(c0, Int((s.right - 0.001) / SP))
            guard s.kind != .menuBar, c1 - c0 < 400 else { return [] }
            // The pointer works over the body of the thing — the icons on
            // the Dock, the face of a widget — and its top edge with it.
            return (c0...c1).map { c in
                let x = (Float(c) + 0.5) * SP
                return max(w(x, s.top + SP * 0.5), w(x, s.top + min(s.h * 0.5, SP * 3)))
            }
        }
        groundWear = (0..<cols).map { c in w((Float(c) + 0.5) * SP, H - SP * 0.5) }
    }

    @inline(__always)
    private func wearAt(_ i: Int, _ cx: Int) -> Float {
        guard i < surfaceWear.count, i < surfaces.count, SP > 0 else { return 0 }
        let row = surfaceWear[i]
        let k = cx - Int(surfaces[i].left / SP)
        return k >= 0 && k < row.count ? row[k] : 0
    }

    /// How many leaves lie in column `c` of surface `i`.
    private func leafDepth(_ i: Int, _ c: Int) -> Int {
        let s = surfaces[i]
        return films[i].lying.reduce(0) { $0 + (leafCell($1, on: s) == c ? 1 : 0) }
    }

    /// Which way is less trodden from column `c` of surface `i`: -1 or 1.
    private func quieterSide(_ i: Int, _ c: Int) -> Int {
        let l = wearAt(i, c - 1) + wearAt(i, c - 2) * 0.5
        let r = wearAt(i, c + 1) + wearAt(i, c + 2) * 0.5
        return abs(l - r) < 0.01 ? (rnd() < 0.5 ? -1 : 1) : (l < r ? -1 : 1)
    }

    /// Scuff lying leaves off the paths: each on a worn spot is pushed a cell
    /// toward the quieter side, now and then — so over a few minutes a path
    /// opens through a pile and the leaves bank up beside it. One at the end
    /// of the lip goes over.
    private func scuffPaths() {
        guard !surfaceWear.isEmpty, SP > 0 else { return }
        for i in films.indices where i < surfaces.count && !films[i].lying.isEmpty {
            let s = surfaces[i]
            guard s.w > 0 else { continue }
            let c0 = Int(s.left / SP), c1 = Int((s.right - 0.001) / SP)
            var k = films[i].lying.count - 1
            while k >= 0 {
                defer { k -= 1 }
                let c = leafCell(films[i].lying[k], on: s)
                let w = wearAt(i, c)
                guard w > 0.12, rnd() < w * 0.5 else { continue }
                let dir = quieterSide(i, c)
                // Over a heap already two deep it slides on to the first spot
                // with room — or off the end.
                var t = c + dir
                while t >= c0, t <= c1, leafDepth(i, t) >= 2 { t += dir }
                if t < c0 || t > c1 {
                    let l = films[i].lying.remove(at: k)
                    launchLeaf(x: dir < 0 ? s.left - SP * 0.3 : s.right + SP * 0.3,
                               y: s.top - SP * 0.2, lift: false, age: l.age, hue: l.hue)
                } else {
                    films[i].lying[k].u = max(0, min(0.999, ((Float(t) + 0.2 + rnd() * 0.6) * SP - s.left) / s.w))
                }
            }
        }
        // Along the bottom the same: a worn column sheds to the quieter one.
        guard groundWear.count == groundLeaves.count else { return }
        var next = groundLeaves
        for c in groundLeaves.indices where groundLeaves[c] > 0.05 && groundWear[c] > 0.12 {
            let l = c > 0 ? groundWear[c - 1] : 9, r = c + 1 < groundWear.count ? groundWear[c + 1] : 9
            let to = l < r ? c - 1 : c + 1
            guard to >= 0, to < groundLeaves.count else { continue }
            let m = groundLeaves[c] * groundWear[c] * 0.4
            next[c] -= m; next[to] = min(1, next[to] + m)
            groundLeafAge[to] = max(groundLeafAge[to], groundLeafAge[c] * 0.5 + groundLeafAge[to] * 0.5)
        }
        groundLeaves = next
    }

    /// Lose each leaf with chance `p` — rotting, blowing off unseen — so a
    /// pile thins out leaf by leaf, from wherever, not from one end.
    private func thin(_ lying: inout [LyingLeaf], by p: Float) {
        guard p > 0 else { return }
        lying.removeAll { _ in rnd() < p }
    }

    /// Something is in the air after a shake — the frame rate should be up
    /// for the second or two it takes to land.
    var hasDebris: Bool { !clumps.isEmpty || drops.contains { $0.splashLife > 0 } }

    /// A surface MOVED — a window dragged, a widget rearranged — and shook off
    /// some of what lay on it: the water on its top edge is thrown up and off
    /// as spray that lands on the pane and runs, and lying snow slides off in
    /// clumps that fall away. The further it went, the more comes off, as a
    /// jolt does; a nudge sheds a little, a fling most of it.
    private func shake(_ i: Int, from old: Surface, by distance: Float) {
        guard i < films.count, SP > 0 else { return }
        var f = films[i]
        release(&f, from: old, share: min(0.85, 0.25 + distance / SP * 0.06))
        films[i] = f
    }

    /// Throw `share` of what lies on `f` off the top of `old`: water as spray
    /// that lands on the pane and runs, snow as clumps, leaves as leaves. A
    /// share of 1 is everything — a window closed or swept away by Show
    /// Desktop does not take its weather with it; it all comes down.
    private func release(_ f: inout SurfaceFilm, from old: Surface, share k: Float) {
        guard SP > 0 else { return }
        let water = (f.wet + f.lip) * k
        // A small share (the pointer brushing past, every frame) rounds by
        // chance, so a brush knocks off a drop now and then, not one a frame.
        let n = min(10, Int(water * 14 + (k < 0.2 ? rnd() : 0)))
        for _ in 0..<n where drops.count < Self.maxDrops {
            let r = SP * (0.22 + rnd() * 0.30)
            drops.append(GlassDrop(x: old.left + rnd() * old.w, y: old.top - r,
                                   r: r, v: -30 - rnd() * 70,
                                   rCrit: SP * (0.5 + rnd() * 0.4), falling: true,
                                   vx: (rnd() - 0.5) * 140, splashLife: 0.45 + rnd() * 0.4))
        }
        f.wet *= 1 - k; f.lip *= 1 - k; f.runoff *= 1 - k
        if f.snow > 0.05 && f.snowSpan > 0.05 {
            let c = k < 0.2 ? Int(f.snow * f.snowSpan * 30 * k + rnd())
                            : min(14, Int(f.snow * f.snowSpan * 8 * k) + 2)
            for _ in 0..<c where clumps.count < 40 {
                clumps.append(Clump(x: old.left + (0.5 + (rnd() - 0.5) * f.snowSpan) * old.w,
                                    y: old.top - SP * 0.5 * rnd(),
                                    vx: (rnd() - 0.5) * 70, vy: -15 - rnd() * 35,
                                    r: SP * (0.35 + rnd() * 0.45)))
            }
            f.snow *= 1 - k
        }
        if !f.lying.isEmpty {
            // Each comes off from where it lay. All of them when the piece
            // is gone; a share, by chance, when it was only jolted.
            let n = k >= 0.999 ? f.lying.count
                : min(f.lying.count, Int(Float(f.lying.count) * k + rnd()))
            for _ in 0..<n {
                let l = f.lying.remove(at: Int(rnd() * Float(f.lying.count)) % f.lying.count)
                launchLeaf(x: old.left + l.u * old.w, y: old.top - SP * 0.4, lift: true,
                           age: l.age, hue: l.hue)
            }
        }
    }

    // MARK: Leaves
    //
    // Asked for 5 Nov 2026: "in areas where there is a proper fall, like
    // Amherst, show leaves blowing in the wind, and leaves scattered — use the
    // things in nature." Built from what was already here: the clumps that fly
    // off a moved window carry them, and they settle on the furniture as a
    // deposit beside the snow and the water, so they are lit, raised and
    // carried exactly like those.

    /// How far into leaf fall it is, 0..1 — from where (latitude) and when (day
    /// of the year). Leaf fall peaks around the 23rd of October at 42°N, a
    /// couple of days earlier per degree further north; the southern
    /// hemisphere has it in April. Only between about 26° and 64°, where the
    /// trees that turn are.
    static func leafSeason(latitude: Float, dayOfYear: Float) -> Float {
        let a = abs(latitude)
        guard a > 26, a < 64, dayOfYear > 0 else { return 0 }
        let peak = 296 - (a - 42) * 2.2
        var d = dayOfYear
        if latitude < 0 { d = (d + 182).truncatingRemainder(dividingBy: 365) }
        let x = (d - peak) / 16
        let edge = min(1, (a - 26) / 6) * min(1, (64 - a) / 6)
        return exp(-x * x) * edge
    }

    /// A leaf in the air. `age` is days it has already lain (a lifted one is
    /// as brown as it was on the ground); a fresh one carries its colour.
    /// A leaf's colour for the shader: its fresh hue (0..1) in the fraction,
    /// its age in two-day steps (0..7) in the whole part.
    static func leafCode(hue: Float, age: Float) -> Float {
        Float(min(7, Int(max(0, age) / 2))) + min(0.999, max(0, hue))
    }

    /// A leaf into the air. Nothing is lost when the air is full: past the
    /// cap a leaf goes straight to the ground below where it was, which is
    /// where it was going anyway.
    private func launchLeaf(x: Float, y: Float, lift: Bool = false, age: Float = 0, hue: Float? = nil) {
        let h = hue ?? rnd()
        guard clumps.count < 60 else {
            if SP > 0 { settleOnGround(x: x, age: age) }
            return
        }
        clumps.append(Clump(x: x, y: y, vx: (rnd() - 0.5) * 60, vy: lift ? -40 - rnd() * 60 : 20,
                            r: SP * 0.45, leaf: true, hue: h, phase: rnd() * 6.28, age: age))
    }

    /// The cell a lying leaf is drawn in.
    @inline(__always)
    private func leafCell(_ l: LyingLeaf, on s: Surface) -> Int {
        Int((s.left + l.u * s.w) / SP)
    }

    /// A leaf comes down on the top edge of surface `i` at `x`. It stays
    /// where it lands — unless the spot is already two deep, when it slides
    /// off the heap to the lower side next to it, as a leaf on a pile does;
    /// and if that is past the end, it goes over and on down. True when it
    /// came to rest here.
    private func settle(on i: Int, x: Float, hue: Float, age: Float) -> Bool {
        let s = surfaces[i]
        guard s.w > 0, SP > 0 else { return false }
        let c0 = Int(s.left / SP), c1 = Int((s.right - 0.001) / SP)
        func depth(_ c: Int) -> Int { films[i].lying.reduce(0) { $0 + (leafCell($1, on: s) == c ? 1 : 0) } }
        // The nearest spot not already two deep, looking a couple of cells
        // either way (whichever side first, by chance); off the end of the
        // lip, or a heap full all round, and it does not stay.
        let at = Int(x / SP), side = rnd() < 0.5 ? -1 : 1
        var found: Int?
        for d in [0, side, -side, 2 * side, -2 * side] {
            let c = at + d
            if c < c0 || c > c1 { if d != 0 { found = c; break } else { continue } }
            if depth(c) < 2 { found = c; break }
        }
        guard var c = found, c >= c0, c <= c1 else { return false }
        // On a path it does not stay put: it is kicked on to the quieter
        // side, a cell or two, as a leaf on a trodden way is.
        let w = wearAt(i, c)
        if w > 0.12, rnd() < w {
            let dir = quieterSide(i, c)
            var t = c + dir, step = 1
            while true {
                if t < c0 || t > c1 { return false }
                if depth(t) < 2 && (wearAt(i, t) < w * 0.5 || step >= 3) { c = t; break }
                t += dir; step += 1
            }
        }
        let cx = (Float(c) + 0.2 + rnd() * 0.6) * SP
        let u = max(0, min(0.999, (cx - s.left) / s.w))
        films[i].lying.append(LyingLeaf(u: u, hue: hue, age: age))
        return true
    }

    /// A leaf comes to rest along the bottom of the screen. A column already
    /// heaped sheds it to the lower neighbour.
    private func settleOnGround(x: Float, age: Float) {
        guard !groundLeaves.isEmpty else { return }
        var c = max(0, min(groundLeaves.count - 1, Int(x / SP)))
        if c < groundWear.count, groundWear[c] > 0.12, rnd() < groundWear[c] {
            let l = c > 0 ? groundWear[c - 1] : 9, r = c + 1 < groundWear.count ? groundWear[c + 1] : 9
            c = max(0, min(groundLeaves.count - 1, l < r ? c - 1 : c + 1))
        }
        if groundLeaves[c] > 0.8 {
            let a = c > 0 ? groundLeaves[c - 1] : 2, b = c + 1 < groundLeaves.count ? groundLeaves[c + 1] : 2
            if min(a, b) < groundLeaves[c] { c = a < b ? c - 1 : c + 1 }
        }
        let had = groundLeaves[c]
        let add: Float = 0.18
        groundLeaves[c] = min(1, had + add)
        groundLeafAge[c] = (groundLeafAge[c] * had + age * add) / max(had + add, 0.001)
    }

    /// Bring leaves down, lift them back off, and age what is lying about.
    ///
    /// Leaves do not RAIN. A tree lets go of them in flurries when a gust
    /// shakes it, and between gusts only the odd one drifts down; a calm day
    /// in the middle of the season sees a few a minute. They come from where
    /// the trees are — off the top of the screen, or carried in from the
    /// upwind side — never conjured mid-air.
    private func updateLeaves(dt: Float, state: SceneState) {
        if groundLeaves.count != cols {
            groundLeaves = [Float](repeating: 0, count: cols)
            groundLeafAge = [Float](repeating: 0, count: cols)
        }
        let season = Self.leafSeason(latitude: state.astro.latitude, dayOfYear: state.astro.dayOfYear)
        leafSeasonNow = season
        let w = state.weather
        let wind = max(0, w.wind)
        let wet = w.isPrecipitating || films.contains { $0.wet > 0.4 }

        // ---- gusts: a few seconds of stronger wind every so often, more
        // often and harder the windier the day.
        if gustLeft > 0 { gustLeft -= dt } else {
            nextGust -= dt
            if nextGust <= 0 {
                gustLeft = 1.5 + rnd() * 3
                nextGust = (wind > 25 ? 6 : wind > 12 ? 14 : 40) * (0.5 + rnd())
            }
        }
        // No wind, no gust: in still air lying leaves stay exactly put.
        let gusting = gustLeft > 0 && wind > 6
        let gust = gusting ? min(1, 0.3 + wind / 35) : 0

        // ---- off the trees. Only the WIND brings them down: in still air a
        // leaf hangs on, and lying ones stay exactly where they are. A breeze
        // lets the odd one go; a gust, a flurry.
        if season > 0.02 && wind > 6 {
            // A gust at 20 km/h brings down two or three; between gusts the
            // odd one a minute. They used to come at several a second in a
            // gust and the furniture filled up in an afternoon.
            let rate = season * (gusting ? 0.3 + wind / 40 : (wind - 6) / 900)
            if rnd() < rate * dt {
                let cw = crossWind
                if abs(cw) > 8 && rnd() < 0.7 {
                    launchLeaf(x: cw > 0 ? -SP : W + SP, y: H * (0.05 + rnd() * 0.45))
                } else {
                    launchLeaf(x: rnd() * W, y: -SP)
                }
            }
        }

        // ---- lying leaves. A gust lifts DRY ones off and skitters the ones
        // along the bottom downwind; wet ones are plastered down and stay.
        if gusting && !wet && gust > 0.3 {
            for i in 0..<min(films.count, surfaces.count) where films[i].leaves > 0.08 {
                if rnd() < films[i].leaves * gust * dt * 0.8 {
                    let s = surfaces[i]
                    let l = films[i].lying.remove(at: Int(rnd() * Float(films[i].lying.count)) % films[i].lying.count)
                    launchLeaf(x: s.left + l.u * s.w, y: s.top - SP * 0.3, lift: true, age: l.age, hue: l.hue)
                }
            }
            // Skitter: some of each column slides a column downwind.
            let dir = crossWind >= 0 ? 1 : -1
            let move = gust * dt * 0.6
            var next = groundLeaves
            for c in 0..<cols where groundLeaves[c] > 0.05 {
                let to = c + dir
                guard to >= 0, to < cols else { continue }
                let m = groundLeaves[c] * move
                next[c] -= m; next[to] = min(1, next[to] + m)
            }
            groundLeaves = next
            if rnd() < gust * dt * 0.5 {
                let c = Int(rnd() * Float(cols))
                if groundLeaves[c] > 0.15 {
                    launchLeaf(x: (Float(c) + 0.5) * SP, y: H - SP, lift: true, age: groundLeafAge[c])
                    groundLeaves[c] = max(0, groundLeaves[c] - 0.18)
                }
            }
        }
        // ---- along the lip. Wind pushes a dry pile toward the downwind end,
        // and what reaches the end goes over it, falling down past the corner
        // — into the gap between widgets, onto whatever is below. Snow does
        // the same in a strong wind when it is dry and cold: it blows off the
        // edge in clumps. Wet leaves and wet snow stay put.
        let cw = crossWind
        let push = max(-1, min(1, cw / 30))
        for i in 0..<min(films.count, surfaces.count) {
            let s = surfaces[i]
            guard s.kind != .menuBar else { continue }
            var f = films[i]
            f.leafRoom = s.w / SP
            // The wind walks dry leaves along the lip a cell at a time — the
            // pile drifts toward the downwind end and what reaches it goes
            // over. Each leaf moves from where IT is, so a pile keeps its
            // shape as it creeps, rather than being redrawn banked.
            if !f.lying.isEmpty, f.wet < 0.3, !w.isPrecipitating, abs(cw) > 10, s.w > 0 {
                let moves = Float(f.lying.count) * abs(push) * dt * (gusting ? 1.2 : 0.06)
                var n = Int(moves + rnd())
                let step = SP / s.w * (push > 0 ? 1 : -1)
                while n > 0, !f.lying.isEmpty {
                    n -= 1
                    let k = Int(rnd() * Float(f.lying.count)) % f.lying.count
                    f.lying[k].u += step
                    if f.lying[k].u < 0 || f.lying[k].u >= 1 {
                        let l = f.lying.remove(at: k)
                        let x = push > 0 ? s.right + SP * 0.3 : s.left - SP * 0.3
                        launchLeaf(x: x, y: s.top - SP * 0.2, lift: false, age: l.age, hue: l.hue)
                    }
                }
            }
            if f.snow > 0.2, w.temperature < -2, f.wet < 0.2, abs(cw) > 25,
               rnd() < f.snow * (abs(cw) - 25) / 60 * dt, clumps.count < 40 {
                let x = cw > 0 ? s.right + SP * 0.2 : s.left - SP * 0.2
                clumps.append(Clump(x: x, y: s.top - SP * 0.5, vx: cw * 2, vy: 0,
                                    r: SP * (0.3 + rnd() * 0.3)))
                f.snow = max(0, f.snow - 0.02)
            }
            films[i] = f
        }

        // The pointer passing along a top edge knocks off what is under it —
        // a little of the water, snow, ice-free slush and leaves just there,
        // falling from that spot. A drag knocks off more than a hover.
        if cursor.stir > 0.2 && SP > 0 {
            for i in 0..<min(films.count, surfaces.count) {
                let s = surfaces[i]
                guard s.kind != .menuBar, cursor.x > s.left, cursor.x < s.right,
                      abs(cursor.y - s.top) < SP * 1.5 else { continue }
                var f = films[i]
                guard f.anyWater > 0.08 || f.snow > 0.08 else { continue }
                var spot = s
                spot.x = max(s.left, cursor.x - SP * 1.2)
                spot.w = min(s.right, cursor.x + SP * 1.2) - spot.x
                let speed = min(1, (abs(cursor.vx) + abs(cursor.vy)) / (SP * 30))
                let share = cursor.stir * speed * dt * 2.5
                guard share > 0.003 else { continue }
                let lying = f.lying
                f.lying = []                     // leaves are handled just below
                release(&f, from: spot, share: min(0.5, share))
                f.lying = lying
                films[i] = f
            }
        }

        // A drag across the desktop scuffs up what lies near the pointer.
        if cursor.stir > 0.3 {
            for i in 0..<min(films.count, surfaces.count) where !films[i].lying.isEmpty {
                let s = surfaces[i]
                guard cursor.x > s.left, cursor.x < s.right, abs(cursor.y - s.top) < SP * 2,
                      s.w > 0, rnd() < dt * 8 else { continue }
                // The leaf under the pointer, if there is one within reach.
                let u = (cursor.x - s.left) / s.w, reach = SP * 1.5 / s.w
                var best = -1, bestD = reach
                for (k, l) in films[i].lying.enumerated() where abs(l.u - u) < bestD { bestD = abs(l.u - u); best = k }
                guard best >= 0 else { continue }
                let l = films[i].lying.remove(at: best)
                launchLeaf(x: s.left + l.u * s.w, y: s.top - SP * 0.3, lift: true, age: l.age, hue: l.hue)
            }
            let c = Int(cursor.x / SP)
            if cursor.y > H - SP * 2, c >= 0, c < groundLeaves.count, groundLeaves[c] > 0.05, rnd() < dt * 8 {
                launchLeaf(x: cursor.x, y: H - SP, lift: true, age: groundLeafAge[c])
                groundLeaves[c] = max(0, groundLeaves[c] - 0.18)
            }
        }

        // ---- age and clear. They brown over days; once the trees are bare
        // they thin out over a couple of weeks. Snow lying on them keeps them.
        // Every ten seconds is plenty for something measured in days.
        leafClock += dt
        guard leafClock >= 10 else { return }
        let day = leafClock / 86400
        leafClock = 0
        refreshWear()
        scuffPaths()
        let clear = leafClearPerDay * day
        for i in films.indices where !films[i].lying.isEmpty {
            for k in films[i].lying.indices { films[i].lying[k].age += day }
            if films[i].snow < 0.1 { thin(&films[i].lying, by: clear / max(0.05, films[i].leaves)) }
        }
        for c in groundLeaves.indices where groundLeaves[c] > 0 {
            groundLeafAge[c] += day
            groundLeaves[c] = max(0, groundLeaves[c] - clear)
        }
    }

    /// One leaf's flight. True when it has landed or left.
    private func flyLeaf(_ k: Int, dt: Float) -> Bool {
        var l = clumps[k]
        // A falling leaf is a PENDULUM, not a stone: it glides one way,
        // stalls as it tips over, drops, and glides back — falling slowest at
        // the bottom of each swing, when it is flat, and fastest at the ends,
        // when it is edge-on. About a metre a second on average, a swing
        // every second or so; the air around it carries it with the wind.
        l.phase += dt * (5.2 + 1.5 * sin(l.hue * 9))
        let swing = cos(l.phase), edge = abs(sin(l.phase))
        let wind = crossWind * W * 0.0016 * (gustLeft > 0 ? 1.6 : 1)
        l.vx += (wind + swing * SP * 2.2 - l.vx) * min(1, dt * 3)
        let terminal = H * 0.04 * (0.35 + 1.3 * edge)
        l.vy += (terminal - l.vy) * min(1, dt * 2.5)
        // The pointer, dragging through the air, sweeps them along.
        if cursor.stir > 0.2 {
            let dx = l.x - cursor.x, dy = l.y - cursor.y
            if dx * dx + dy * dy < (SP * 5) * (SP * 5) {
                l.vx += cursor.vx * cursor.stir * dt * 3
                l.vy += cursor.vy * cursor.stir * dt * 3
            }
        }
        let prevY = l.y
        l.x += l.vx * dt
        l.y += l.vy * dt
        clumps[k] = l
        // Lands on a top edge it falls across.
        for i in 0..<min(films.count, surfaces.count) where surfaces[i].kind != .menuBar {
            let s = surfaces[i]
            if l.x > s.left, l.x < s.right, prevY < s.top, l.y >= s.top {
                // Caught on the very edge, it tips off and carries on down —
                // into the gap between two widgets, or past the corner.
                let fromEnd = min(l.x - s.left, s.right - l.x)
                if fromEnd < SP * 0.6 {
                    clumps[k].x = l.x < (s.left + s.right) / 2 ? s.left - SP * 0.4 : s.right + SP * 0.4
                    clumps[k].vy = max(clumps[k].vy, 30)
                    return false
                }
                if settle(on: i, x: l.x, hue: l.hue, age: l.age) { return true }
                // Slid off the heap past the end: on down it goes.
                clumps[k].x = l.x < (s.left + s.right) / 2 ? s.left - SP * 0.4 : s.right + SP * 0.4
                clumps[k].vy = max(clumps[k].vy, 30)
                return false
            }
        }
        if l.y > H - SP * 0.5 {
            if l.x >= 0, l.x < W { settleOnGround(x: l.x, age: l.age) }
            return true
        }
        return l.x < -SP * 3 || l.x > W + SP * 3
    }

    private func updateClumps(dt: Float) {
        guard !clumps.isEmpty else { return }
        for k in clumps.indices.reversed() {
            if clumps[k].leaf {
                if flyLeaf(k, dt: dt) { clumps.remove(at: k) }
                continue
            }
            clumps[k].vy += 1100 * dt
            clumps[k].vx *= 1 - dt * 0.8
            clumps[k].x += clumps[k].vx * dt
            clumps[k].y += clumps[k].vy * dt
            // Snow falling through air sheds itself: the clump crumbles.
            clumps[k].r *= 1 - dt * 0.25
            if clumps[k].y > H + clumps[k].r || clumps[k].r < SP * 0.12 { clumps.remove(at: k) }
        }
    }
    private var spots: [GlassSpot] = []
    private var vortices: [GlassVortex] = []
    private(set) var glassWet: Float = 0
    /// How hard it is raining right now, 0..1. Drives how strongly water marks
    /// the pane, so the effect tracks the forecast rather than being constant.
    private(set) var rainIntensity: Float = 0

    // MARK: How fast lying snow and ice go
    //
    // THESE WERE A HUNDRED TIMES TOO FAST. Measured with the render tool's
    // --dryfor thaw: three minutes of snow at -3C, then a 6C overcast
    // afternoon, and a full cap (3.4 cells) was gone inside SIXTY SECONDS.
    // Sublimation alone — below freezing, in the dry — took a thick cap off in
    // about two hours. Real snow on a ledge at 6C lasts hours, and dry cold
    // takes days; the whole point of snow on the furniture is that after a
    // heavy fall it STAYS.
    //
    // Degree-hour melt, which is how snowmelt is actually modelled: a rate per
    // degree above zero, plus sunshine (UV as its proxy), plus wind (warm air
    // mixed down onto the snow), plus rain falling on it, which melts snow far
    // faster than air of the same temperature. Tuned so a 3.4-cell cap lasts
    // about two hours at 6C overcast and forty minutes on a hot sunny day.

    /// Cells of depth lost per second: (melt, sublimation).
    static func snowLoss(temp t: Float, uv: Float, wind: Float,
                         evap: Float, raining: Bool) -> (Float, Float) {
        let warm = max(0, t)
        var melt = warm * 0.000055 * (1 + min(1.5, wind / 30))
                 + max(0, uv - 1) * 0.00005 * (t > -2 ? 1 : 0)
        if raining && t > 0 { melt *= 2.2 }
        let sublime = 0.000012 * (0.3 + evap * 2)
        return (melt, sublime)
    }

    /// Glaze lost per second.
    static func glazeThaw(temp t: Float, uv: Float) -> Float {
        max(0, t) * 0.00004 + max(0, uv - 2) * 0.00003
    }

    // MARK: Remembering what is lying on the furniture
    //
    // Snow that has settled stays through a restart, a sleep or an update. The
    // host saves this every minute and on sleep and quit; on launch it hands
    // it back, the pieces are matched to the furniture by kind and position,
    // and the time away is aged at the weather that was last seen.

    struct FurnitureMemory: Codable {
        var kind: Int32
        /// Centre, as a fraction of the screen, so it survives a change of
        /// grid or resolution.
        var cx: Float, cy: Float
        var snow: Float, snowSpan: Float, glaze: Float, frost: Float, grime: Float
        /// Optional so a snapshot written before leaves existed still decodes.
        var leaves: Float? = nil
        var leafAge: Float? = nil
        /// Each leaf, where it lay along the edge. Older snapshots have only
        /// `leaves`, a cover; those are scattered back.
        var lying: [LyingLeaf]? = nil
    }

    struct FurnitureSnapshot: Codable {
        var saved: Date
        var temperature: Float
        var uv: Float
        var wind: Float
        var items: [FurnitureMemory]
        /// Leaves lying along the bottom of the screen, per column across it
        /// (resampled on restore), and their age in days.
        var ground: [Float]? = nil
        var groundAge: [Float]? = nil
    }

    func furnitureSnapshot(now: Date = Date()) -> FurnitureSnapshot? {
        guard films.count == surfaces.count, W > 0, H > 0 else { return nil }
        let items: [FurnitureMemory] = surfaces.indices.compactMap { i in
            let f = films[i], s = surfaces[i]
            guard f.snow > 0.01 || f.glaze > 0.01 || f.frost > 0.01 || f.grime > 0.01
                    || f.leaves > 0.01 else { return nil }
            return FurnitureMemory(kind: s.kind.rawValue,
                                   cx: (s.left + s.w / 2) / W, cy: (s.top + s.h / 2) / H,
                                   snow: f.snow, snowSpan: f.snowSpan, glaze: f.glaze,
                                   frost: f.frost, grime: f.grime,
                                   leaves: f.leaves, leafAge: f.leafAge,
                                   lying: f.lying.isEmpty ? nil : f.lying)
        }
        let anyGround = groundLeaves.contains { $0 > 0.01 }
        return FurnitureSnapshot(saved: now, temperature: lastWeather.temperature,
                                 uv: lastWeather.uv, wind: lastWeather.wind, items: items,
                                 ground: anyGround ? groundLeaves : nil,
                                 groundAge: anyGround ? groundLeafAge : nil)
    }

    /// Held until the furniture exists to put it on — and kept for a while
    /// after, because the furniture arrives in pieces: the Dock and the
    /// widgets first, app windows as the window list catches up. A piece is
    /// crossed off once it has found its place; whatever has not found one
    /// within half a minute is let go.
    private var pendingMemory: FurnitureSnapshot?
    private var pendingUntil = Date.distantPast
    private var pendingGround = false

    func restoreFurniture(_ snap: FurnitureSnapshot, now: Date = Date()) {
        pendingMemory = snap
        pendingUntil = now.addingTimeInterval(30)
        pendingGround = snap.ground != nil
        applyPendingMemory(now: now)
    }

    private func applyPendingMemory(now: Date = Date()) {
        guard var snap = pendingMemory, films.count == surfaces.count,
              !surfaces.isEmpty, W > 0, H > 0, SP > 0 else { return }
        if now > pendingUntil { pendingMemory = nil; return }
        var left: [FurnitureMemory] = []
        // The time away, aged at the last weather seen. Night has no sun, so
        // the sunshine term is dropped for anything longer than a few hours.
        let away = Float(max(0, min(14 * 86400, now.timeIntervalSince(snap.saved))))
        let uv = away > 4 * 3600 ? 0 : snap.uv
        let (melt, sublime) = Self.snowLoss(temp: snap.temperature, uv: uv, wind: snap.wind,
                                            evap: 0.2, raining: false)
        for m in snap.items {
            // Nearest piece of the same kind within a tenth of the screen.
            var best = -1, bestD: Float = 0.1
            for (i, s) in surfaces.enumerated() where s.kind.rawValue == m.kind {
                let dx = (s.left + s.w / 2) / W - m.cx, dy = (s.top + s.h / 2) / H - m.cy
                let d = (dx * dx + dy * dy).squareRoot()
                if d < bestD { bestD = d; best = i }
            }
            guard best >= 0 else { left.append(m); continue }
            var f = films[best]
            let snow = max(0, m.snow - away * (melt + sublime))
            f.snow = max(f.snow, snow)
            f.snowSpan = snow > 0.01 ? max(f.snowSpan, m.snowSpan * min(1, snow / max(m.snow, 0.01)).squareRoot()) : f.snowSpan
            f.glaze = max(f.glaze, max(0, m.glaze - away * (Self.glazeThaw(temp: snap.temperature, uv: uv) + 0.00002)))
            f.frost = max(f.frost, snap.temperature < 0 && away < 6 * 3600 ? m.frost : 0)
            f.grime = max(f.grime, m.grime)
            // Leaves wait exactly where they were, a little older — the days
            // away counted, and thinned only by the slow clearing.
            if f.lying.isEmpty {
                let days = away / 86400
                f.leafRoom = surfaces[best].w / SP
                if let ls = m.lying, !ls.isEmpty {
                    f.lying = ls.map { LyingLeaf(u: $0.u, hue: $0.hue, age: $0.age + days) }
                } else if let l = m.leaves, l > 0.01 {
                    // An older snapshot: only how covered it was.
                    let n = Int(l * max(3, f.leafRoom))
                    f.lying = (0..<n).map { k in
                        LyingLeaf(u: jitter(Float(k) * 7.3 + m.cx * 31), hue: jitter(Float(k) * 3.1 + 5),
                                  age: (m.leafAge ?? 0) + days)
                    }
                }
                thin(&f.lying, by: min(1, days * leafClearPerDay / max(0.05, f.leaves)))
            }
            films[best] = f
        }
        snap.items = left
        pendingMemory = left.isEmpty && !pendingGround ? nil : snap
        if pendingGround, let g = snap.ground, !g.isEmpty, cols > 0 {
            pendingGround = false
            if left.isEmpty { pendingMemory = nil }
            let days = away / 86400
            groundLeaves = (0..<cols).map { c in
                max(0, g[min(g.count - 1, c * g.count / cols)] - days * leafClearPerDay)
            }
            let ga = snap.groundAge ?? []
            groundLeafAge = (0..<cols).map { c in
                (ga.isEmpty ? 0 : ga[min(ga.count - 1, c * ga.count / cols)]) + days
            }
        }
    }

    /// Things on screen for water to land on. Set by the host; empty means the
    /// pane is unobstructed.
    ///
    /// The film state is parallel to this array, so replacing the furniture —
    /// a display change, the dock moving edge — starts the new pieces dry
    /// rather than inheriting the old ones' weather.
    ///
    /// When the list changes, what each piece is carrying FOLLOWS IT: a new
    /// surface inherits the film of the old one of the same kind nearest to
    /// it. App windows are furniture now, and they come and go and move all
    /// the time; resetting every film whenever the count changed would wipe
    /// the snow off every widget the moment a window opened.
    var surfaces: [Surface] = [] {
        didSet {
            let oldFilms = films
            let span = max(W, H, 1)
            var used = Set<Int>()
            var next = [SurfaceFilm](repeating: SurfaceFilm(), count: surfaces.count)
            var moved: [(i: Int, from: Surface, by: Float)] = []
            for (i, s) in surfaces.enumerated() {
                var best = -1, bestD = span * 0.15
                for (j, o) in oldValue.enumerated()
                    where j < oldFilms.count && !used.contains(j) && o.kind == s.kind {
                    let dx = (o.left + o.w / 2) - (s.left + s.w / 2)
                    let dy = (o.top + o.h / 2) - (s.top + s.h / 2)
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d < bestD { bestD = d; best = j }
                }
                if best >= 0 {
                    used.insert(best); next[i] = oldFilms[best]
                    if bestD > SP * 0.4 { moved.append((i, oldValue[best], bestD)) }
                }
            }
            films = next
            refreshWear()
            // Whatever lay on a piece that is GONE — closed, minimised, swept
            // aside by Show Desktop — falls from where it was.
            for (j, o) in oldValue.enumerated()
                where j < oldFilms.count && !used.contains(j) && o.kind != .dock && o.kind != .menuBar {
                var f = oldFilms[j]
                if f.anyWater > 0.05 || f.snow > 0.05 || f.leaves > 0.04 { release(&f, from: o, share: 1) }
            }
            applyPendingMemory()
            for m in moved where surfaces[m.i].kind != .dock && surfaces[m.i].kind != .menuBar {
                shake(m.i, from: m.from, by: m.by)
            }
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
    /// Rings spreading on the standing water where rain lands in it: x in
    /// pixels, age in seconds.
    private var ripples: [(x: Float, t: Float)] = []

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

    /// Deterministic by default, and that is a TESTABILITY decision.
    ///
    /// This was `SystemRandomNumberGenerator`, so two identical invocations of
    /// the offscreen renderer produced different frames — measured at a mean
    /// difference of 8.9/255 across 44% of pixels, from the three breathers
    /// alone. Every before/after comparison the harness can make was therefore
    /// noise-limited, and `--analyze` in particular could not tell a real
    /// regression from a reseed. A harness that cannot reproduce its own output
    /// cannot prove anything, which is most of what a harness is for.
    ///
    /// Nothing here wants system entropy. The breathers are three drifting light
    /// pockets whose whole job is to look unplanned, and they look exactly as
    /// unplanned from a fixed seed — the variety is in the drift, not in where
    /// they started. ELEMENTAL_SEED overrides it if a different arrangement is
    /// ever wanted, and a genuinely random one is `ELEMENTAL_SEED=$RANDOM`.
    ///
    /// SplitMix64 rather than the system generator: tiny, well-distributed, and
    /// — the point — identical on every machine and every OS version, so a
    /// measurement taken here reproduces on somebody else's Mac.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private var rng: SeededRNG = {
        let env = ProcessInfo.processInfo.environment["ELEMENTAL_SEED"]
        return SeededRNG(state: UInt64(env ?? "") ?? 0x5EED_E1E3_0A11_C0DE)
    }()

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
    /// Rows to use when the user has not picked a number.
    ///
    /// A ROW COUNT IS THE WRONG THING TO FIX ACROSS DISPLAYS, which is why this
    /// exists. Cell size is `height / rows`, so a fixed count gives a different
    /// physical tile on every screen: 62 rows is a fine mosaic on a laptop and a
    /// wall of bathroom tiles on a 27-inch monitor at the same viewing distance.
    /// What should stay constant is how big a tile actually LOOKS, so the target
    /// here is a cell size in POINTS — device-independent by definition — and
    /// the row count falls out of whatever display it lands on.
    ///
    /// 21.5 pt is not invented: it is the cell size the user arrived at by hand
    /// after living with it (62 rows on a 2658 px display at 2x), which is
    /// better evidence than any reasoning from first principles about acuity.
    static func autoRows(pixelHeight: Float, scale: Float) -> Int {
        let targetPoints: Float = 21.5
        let cell = max(6, (targetPoints * max(1, scale)).rounded())
        // Bounded at both ends. Below about a dozen rows it stops being a mosaic
        // and becomes colour blocking; past 160 the cells approach the point
        // where the grid disappears and it is just a blurry photograph.
        return max(12, min(160, Int((pixelHeight / cell).rounded())))
    }

    /// Row counts that tile THIS display exactly, ascending.
    ///
    /// EXACT, NOT NEARLY. Every cell is `height / rows` tall and
    /// `width / cols` wide, so `cols` cells span the width and `rows` cells span
    /// the height with nothing left over: no part-cell at any edge, no offset,
    /// the outermost ranks flush against all four sides. That is what the shader
    /// has always drawn — it derives the pitch per axis from the display size —
    /// and this is now the one place that agrees with it.
    ///
    /// What varies from one row count to the next is only how SQUARE the cells
    /// come out, because `cols` has to be a whole number: 62 rows on a
    /// 4112x2658 surface wants 95.9 columns, gets 96, and each cell is 0.1%
    /// wider than it is tall. A row count is allowed if that error is within
    /// 0.3% — a fifth of a pixel across a 60-pixel tile, below anything the eye
    /// can find. Most counts qualify; the ones that do not are coarse grids
    /// where a whole column is a big fraction of the width, and those are
    /// dropped rather than drawn visibly oblong.
    ///
    /// THE WHOLE-PIXEL PITCH THIS REPLACES never reached the screen. It was
    /// computed here and thrown away by the shader, which stretched the rounded-
    /// up grid back over the display — so the "clean pitch" tolerance was only
    /// ever choosing counts, and the stretch it was supposed to prevent happened
    /// anyway. Fractional pitch is safe because every edge in the tile is now
    /// antialiased against the cell's own size, grout included; the uneven
    /// grout that once argued for whole pixels came from one hard-edged test.
    ///
    /// Always measure against `NSScreen.frame * backingScaleFactor`, never the
    /// panel's native size: they differ whenever a scaled mode is in use.
    static let squareTolerance: Float = 0.003
    static let rowRange = 9...300

    static func fittingRows(pixelWidth: Float, pixelHeight: Float) -> [Int] {
        guard pixelWidth > 0, pixelHeight > 0 else { return [] }
        // Never finer than 8 pixels a cell: below that the tile stops having an
        // inside for the finish to happen in.
        let hi = min(rowRange.upperBound, max(rowRange.lowerBound, Int(pixelHeight / 8)))
        return (rowRange.lowerBound...hi).filter {
            squareness(rows: $0, pixelWidth: pixelWidth, pixelHeight: pixelHeight) <= squareTolerance
        }
    }

    /// Columns for a row count: the whole number that keeps cells squarest.
    static func columns(rows: Int, pixelWidth: Float, pixelHeight: Float) -> Int {
        max(1, Int((pixelWidth * Float(rows) / pixelHeight).rounded()))
    }

    /// How far from square a cell is at this row count, as a fraction.
    static func squareness(rows: Int, pixelWidth: Float, pixelHeight: Float) -> Float {
        let c = columns(rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        return abs((pixelWidth / Float(c)) / (pixelHeight / Float(rows)) - 1)
    }

    static func gridGeometry(pixelWidth: Float, pixelHeight: Float,
                             gridRows: Int,
                             scale: Float = 2) -> (cols: Int, rows: Int, pitch: Float) {
        // 0 means "choose for me".
        let want = gridRows > 0 ? gridRows : autoRows(pixelHeight: pixelHeight, scale: scale)

        // ONLY A SIZE THAT FITS THIS DISPLAY. The request is a preference; the
        // count drawn is the nearest one that tiles exactly — see
        // `fittingRows`. Snapped here, in the one function every surface derives
        // its grid from, so the wallpaper, the saver, the lock still and the
        // furniture detector all agree on where the grout is.
        //
        // Nearest in RATIO rather than in rows, because one row matters far
        // more to a 12-row grid than to a 200-row one.
        let fit = fittingRows(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let rows = fit.min(by: { abs(log(Float($0) / Float(want))) < abs(log(Float($1) / Float(want))) })
            ?? max(1, want)
        let cols = columns(rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        return (cols, rows, pixelHeight / Float(rows))
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
        // From the RATE, not a fixed minute-to-four-minutes. On the peak night
        // of a shower the first meteor should not be four minutes away.
        shootT = sec + nextMeteorGap()
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
        // Satellite-reconciled where a satellite answered and the tops are warm
        // enough to be this deck rather than something above it; the plain
        // modelled figure otherwise. See `reconciledLowCloud`.
        var deckCover = w.reconciledLowCloud
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
        // Carried the way the wind blows across the screen. A dead calm keeps
        // the old slow drift so the edge never stands still.
        let cw = Self.crossWind(w, facingAz: facingAz)
        let windSign: Float = abs(cw) < 1 ? 1 : (cw > 0 ? 1 : -1)
        for c in 0..<cols {
            let cx = Float(c) * SP
            let n = 0.5
                  + 0.28 * sin(cx * 0.012 - sec * spd * windSign)
                  + 0.18 * sin(cx * 0.027 - sec * spd * 1.4 * windSign + 2.1)
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
        applySatelliteToDeck(weather: w)
    }

    /// Put the deck where the satellite says the cloud actually is.
    ///
    /// Everything above this line is invented. `n` is three sine waves, and its
    /// only claim is that the deck averages out to the measured cover — so the
    /// AMOUNT of cloud has always been right and its ARRANGEMENT has always been
    /// fiction. On a broken-cloud afternoon that is the most visible remaining
    /// lie in the scene, because the one thing anybody can check by looking up
    /// is whether there is a hole where the window is showing one.
    ///
    /// REDISTRIBUTES, it does not rescale. The profile is divided by its own
    /// mean before it is applied, so this moves cloud from where the satellite
    /// sees a gap to where it sees a mass and leaves the total alone. That
    /// split is the honest one: infrared sees the top of the atmosphere and can
    /// say where cloud is but not how deep it runs, while the model knows the
    /// depth and nothing about the shape. Taking the amount from the satellite
    /// as well would throw away the better source for it and double-count the
    /// coverage that `reconciledLowCloud` has already weighed.
    ///
    /// Blended for the same two reasons radar is: the sampled window is far
    /// wider than the strip of sky a window shows, so applying it raw would
    /// compress a frontal system into the frame; and a limb view has navigation
    /// error the procedural field does not. So it biases the deck rather than
    /// dictating it, and with no satellite the field is exactly what it was.
    private func applySatelliteToDeck(weather w: WeatherState) {
        guard let s = w.sat, s.profile.count >= 4, !edgeArr.isEmpty else { return }
        let prof = s.profile
        let mean = prof.reduce(0, +) / Float(prof.count)
        // A near-empty profile has no arrangement to contribute, and dividing
        // by it would turn sensor noise into cloud banks.
        guard mean > 0.02 else { return }

        for c in 0..<cols {
            // Same mapping radar uses, so the two describe the same piece of
            // sky: the centre of the frame is the centre of the sampled window
            // and the frame spans a modest slice of it.
            let t = (Float(c) / Float(max(1, cols - 1)) - 0.5) * 0.42 + 0.5
            let fi = t * Float(prof.count - 1)
            let i0 = max(0, min(prof.count - 1, Int(fi)))
            let i1 = min(prof.count - 1, i0 + 1)
            let f = fi - Float(i0)
            let cloud = prof[i0] * (1 - f) + prof[i1] * f

            // Relative to the window's own average: 1 is a typical column, 2 is
            // twice the cloud of a typical one, 0 is a hole.
            let rel = cloud / mean
            // Faded out toward the limb: a grazing view displaces cloud far
            // enough horizontally that arranging the deck by it would be
            // confidently wrong rather than vaguely right.
            let k: Float = 0.45 * s.confidence
            let factor = max(0.25, min(2.2, 1 + (rel - 1) * k))
            edgeArr[c] *= factor
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
        // Showers travel WITH the wind, all of their scales the same way.
        let cws = Self.crossWind(w, facingAz: facingAz)
        let showerSign: Float = abs(cws) < 1 ? 1 : (cws > 0 ? 1 : -1)

        // How much of the structure survives. At `patchiness` 0 the field is
        // flat — uniform is what frontal rain IS, not a failure to be
        // interesting — and by 0.7 the gaps run all the way down to dry.
        // Softer than it was (1.45 and 0.72). At those values a showery
        // reading gated whole stretches of the frame completely dry, and the
        // longest scale is wider than the frame — so light showers ended up
        // falling in one corner of the screen and nowhere else, which the user
        // took, fairly, for a bug. Showers now show as heavier and lighter
        // bands across the whole view.
        let shape = min(1, patch * 1.0)
        let gate = patch * 0.40
        let span = max(0.18, 1 - gate)
        let inv = 6.2832 / Float(max(1, cols))

        for c in 0..<cols {
            let a = Float(c) * inv
            // Three scales. The longest is WIDER THAN THE FRAME, so the whole
            // view can go quiet at once — a shower that only ever moved from one
            // side of the window to the other would never actually stop, and
            // stopping is most of what makes a shower a shower.
            let n = 0.50
                  + 0.30 * sin(a * 0.6 - drift * 0.55 * showerSign + 0.7)
                  + 0.22 * sin(a * 2.3 - drift * 0.90 * showerSign + 2.4)
                  + 0.14 * sin(a * 6.1 - drift * 1.60 * showerSign + 5.1)
            var v = max(0, min(1, (n - gate) / span))
            v = 1 - shape * (1 - v)
            if band > 0.01 {
                // A squall line is a LINE, not a blotch: narrow crests, high
                // contrast, moving fast. The rain arrives as a wall and leaves
                // as one, which is why a squall is over in minutes.
                let s = sin(a * 1.4 - drift * 2.6 * showerSign + 1.1)
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
        guard prof.count >= 4 else { floorPrecipField(); return }
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
        floorPrecipField()
    }

    /// If it is raining where you are, it is raining across the view. The
    /// field shapes WHERE it falls harder; it may not leave a column dry.
    private func floorPrecipField() {
        for c in 0..<precipField.count { precipField[c] = max(precipField[c], 0.25) }
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
        let cross = Self.crossWind(weather, facingAz: facingAz)
        let push = abs(cross) > 3 ? cross / 22 : 0
        let slope = max(-2.5, min(2.5, push / max(baseSpeed, 0.05)))
        // UPWIND OF THE FRAME. A streak drifts `slope` columns for every row it
        // falls, and they were only ever born over the frame's own columns — so
        // in any wind the upwind side of the lower screen could never be
        // reached, and the rain piled into the downwind corner. The user saw
        // exactly that: "all collecting in one corner". Rain out of a window
        // arrives from beyond its edge, so streaks are born across the frame
        // AND across the strip upwind of it they will drift in from, with the
        // rate and the cap widened in proportion so the density is unchanged.
        let reach = min(Float(cols) * 2, abs(slope) * Float(rows))
        let widen = (Float(cols) + reach) / Float(max(1, cols))
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

        spawnAccum += perSecond * dt * widen
        // Bounded, so one long frame cannot turn into a burst.
        spawnAccum = min(spawnAccum, 12 * widen)
        while spawnAccum >= 1 {
            spawnAccum -= 1
            guard streaks.count < Int(Float(maxStreaks) * widen) else { break }
            // Pick a column WEIGHTED BY THE FIELD, by rejection. A dry gap
            // simply fails to place anything — which is what makes the gap dry
            // rather than merely dimmer, and dimmer is not what a shower does.
            var col = -1
            var cBirth: Float = 0
            for _ in 0..<4 {
                // Across the frame plus the upwind strip. Off-frame births read
                // the field and the deck at the nearest edge column.
                var cf = rnd() * (Float(cols) + reach)
                if slope > 0 { cf -= reach }
                let t = max(0, min(cols - 1, Int(cf.rounded(.down))))
                guard edgeArr[t] > 0 else { continue }
                if rnd() < precipField[t] { col = t; cBirth = cf.rounded(.down); break }
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
            // Nothing is born inside a shelter: under a widget it is dry.
            // DEPTH. The rain is a volume, not a sheet. Only the part of it
            // nearest the glass is at the widgets' distance and can meet them;
            // the rest falls far beyond them, passes behind them, and carries
            // on below. So each streak gets a depth: about a third are NEAR
            // (1.0) — brightest, longest, fastest, the only ones that land on a
            // widget and splash — and the rest are background at 0.35-0.8,
            // dimmer, shorter and slower the further off they are. Without
            // this every streak stopped on the widgets and left the screen
            // under them dry, which read as rain "missing a corner".
            let near = rnd() < 0.3
            let depth: Float = near ? 1 : 0.35 + rnd() * 0.45
            // Nothing NEAR is born inside a shelter: under a widget, close to
            // the glass, it is dry. The background does not care.
            if near, shelterTop(atX: (cBirth + 0.5) * SP, below: y0 * SP) != nil { continue }

            streaks.append((c: cBirth, y: y0,
                            len: lenBase * (0.75 + rnd() * 0.5) * (0.55 + 0.45 * depth),
                            v: baseSpeed * (0.72 + rnd() * 0.56) * (0.6 + 0.4 * depth),
                            slope: slope * (0.85 + rnd() * 0.3),
                            wob: wobble * (0.4 + rnd() * 1.2),
                            ph: rnd() * 6.2832,
                            hops: 0, stop: .infinity, resume: .infinity, depth: depth))
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
            let prevY = streaks[i].y
            streaks[i].y += dy
            // The head travels along the slope, so the whole streak leans.
            streaks[i].c += streaks[i].slope * dy

            // DRAG. The pointer is an UMBRELLA to rain — drops swerve round it
            // to either side — and a hand stirring snow, which swirls round it.
            if cursor.stir > 0.02 {
                let hx = (streaks[i].c + 0.5) * SP, hy = streaks[i].y * SP
                let ddx = hx - cursor.x, ddy = hy - cursor.y
                let dist = (ddx * ddx + ddy * ddy).squareRoot()
                let R = SP * 7
                if dist < R && dist > 1 {
                    let k = cursor.stir * (1 - dist / R) * f
                    let pf = lastWeather.precipForm
                    if pf == .snow || pf == .snowGrains || pf == .graupel {
                        streaks[i].c += (-ddy / dist) * k * 0.6
                        streaks[i].y += (ddx / dist) * k * 0.6
                    } else {
                        streaks[i].c += (ddx >= 0 ? 1 : -1) * k * 0.7
                    }
                }
            }

            // LANDING. Rain used to fall straight through the dock and every
            // widget as if they were not there — the one thing that made the
            // furniture look untouched by weather however much the physics
            // behind it did. Now a streak whose head crosses a top edge stops
            // there: the head is pinned to the edge, the tail drains into it,
            // and it throws a splash where it hit. Since nothing is born inside
            // a shelter either, every piece of furniture casts a rain shadow
            // below it, slanted by the same wind that slants the rain.
            // Free, or already out from under the last thing it landed on.
            // Only NEAR rain can meet the furniture; the background passes behind.
            if streaks[i].depth > 0.99
                && (streaks[i].stop.isInfinite || prevY - streaks[i].len > streaks[i].resume)
                && streaks[i].v > 0 {
                let hx = (streaks[i].c + 0.5) * SP
                for (k, sf) in surfaces.enumerated()
                    where sf.kind != .menuBar && hx >= sf.left && hx <= sf.right {
                    let topRow = sf.top / SP
                    if prevY < topRow && streaks[i].y >= topRow {
                        streaks[i].stop = topRow
                        // A SHORT shadow, then the rain picks up again. The
                        // widget is stuck to the glass: it shelters the strip
                        // just under it, not everything down to the Dock — a
                        // full-height shadow under a row of widgets left whole
                        // corners of the screen without rain. Uneven per streak,
                        // so the shadow's lower edge is ragged, not ruled.
                        streaks[i].resume = (sf.bottom + sf.h * (0.25 + rnd() * 0.8) + SP * 1.5) / SP
                        if marks(sf.kind), films.count == surfaces.count,
                           Furniture.options.furniture > 0.001,
                           drops.count < Self.maxDrops + 28, rnd() < 0.7 {
                            let v = max(40, min(520, lastWeather.fallSpeed * 42))
                            let r = SP * (0.30 + rnd() * 0.26) * (form == .hail ? 1.5 : 1)
                            splash(at: GlassDrop(x: hx, y: sf.top, r: r, v: v,
                                                 rCrit: SP * 0.5, falling: true),
                                   on: k)
                        }
                        break
                    }
                }
            }

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
                // Off the side only once it is heading AWAY — a streak born
                // upwind is off the frame on purpose and on its way in.
                || (streaks[i].c < -4 && streaks[i].slope <= 0)
                || (streaks[i].c > Float(cols) + 4 && streaks[i].slope >= 0)
                || streaks[i].c < -Float(cols) * 2 - 8 || streaks[i].c > Float(cols) * 3 + 8 {
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
                // Below the edge it landed on, the streak is inside the
                // furniture — hidden by it — so none of it is drawn.
                if ry > s.stop && ry < s.resume { k += step; continue }
                let row = ry * fn
                // The wander is a function of WHERE the point is, not of how
                // old it is, so a fluttering crystal traces one fixed wavy path
                // down the frame instead of shivering in place.
                let wob = wobbly ? s.wob * sin(s.ph + ry * 0.55) : 0
                let col = (s.c - s.slope * k + wob) * fn + (fn - 1) * 0.5
                k += step
                // Never inside a widget's outline, whichever way it got there —
                // a streak slanting in from the side showed through a
                // translucent widget's edge.
                if insideFurniture((col + 0.5) / fn * SP, ry * SP) { continue }
                let fy = Int(row), fx = Int(col.rounded())
                guard fy >= 0, fy < fh, fx >= 0, fx < fw else { continue }
                let idx = fy * fw + fx
                // Brightest at the head, and dimmer the further off it falls.
                let v = (1 - k / s.len) * (0.45 + 0.55 * s.depth)
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

    /// Rate and radiant of whatever shower is running, set by the host from
    /// `Astro.activeShower`. Zero rate means only sporadics.
    /// Meteors spawned since start. Verification only — a still frame cannot
    /// distinguish "none happened" from "one happened and has faded".
    private(set) var shootCount = 0
    var meteorRatePerHour: Float = 0
    var meteorRadiantX: Float = -1      // screen px, -1 when there is no radiant
    var meteorRadiantY: Float = -1

    /// Meteors, at the rate the sky actually has them.
    ///
    /// This used to fire every two to six minutes on any clear night, which is
    /// roughly 10-30 an hour, every night of the year. Real meteor rates are not
    /// like that at all. A quiet night gives a handful of SPORADICS — about five
    /// an hour to a dark-sky observer, fewer in a city — and then a few nights a
    /// year a shower runs and the rate goes up by an order of magnitude.
    /// Flattening that away removes the only thing about meteors worth showing:
    /// that tonight is different from last night.
    ///
    /// So the rate is now sporadic background PLUS whatever `Astro.activeShower`
    /// says, which is measured — the IMO's dates, radiants and ZHRs, cut down by
    /// how far from the peak it is and how high the radiant sits. On 12 August
    /// from northern India that is about 60 an hour after midnight and nothing
    /// before the radiant rises; in September it is sporadics only.
    ///
    /// The individual meteors are still generated. Nothing observes a meteor
    /// before it burns, so this is simulation shaped by real data rather than
    /// observation, and that is a weaker claim than the radar makes. What is
    /// real is WHEN and HOW MANY and WHERE FROM.
    /// Seconds until the next meteor, from the rate the sky actually has.
    ///
    /// Sporadics are real and roughly constant — about five an hour to a
    /// dark-sky observer, and this is a wallpaper on a desk in a city, so the
    /// low end. A shower adds to that rather than replacing it.
    private func nextMeteorGap() -> Float {
        let sporadic: Float = 3
        let perHour = sporadic + max(0, meteorRatePerHour)
        let mean = 3600 / max(0.5, perHour)
        // Jittered so they do not arrive on a metronome.
        return mean * (0.55 + rnd() * 0.9)
    }

    private func updateShootingStar(sec: Float, sunAlt: Float, kind: SceneKind) {
        // Daylight and heavy cloud end it. A thin deck does not: you can see a
        // bright meteor through broken cloud, which is why this is not gated on
        // `kind == .sun` alone the way it used to be.
        guard sunAlt < -6 else { shootActive = false; return }
        guard kind != .rain && kind != .snow && kind != .thunder else {
            shootActive = false
            return
        }

        if shootActive && sec - shootT0 > 0.8 { shootActive = false }

        // `shootT` starts at a "never scheduled" sentinel, and the old code
        // seeded it from a fixed 60-240s constant elsewhere. Seed it from the
        // RATE instead, here, the first time we are asked — otherwise the first
        // meteor of a session ignores the shower entirely and the busiest night
        // of the year opens as quietly as any other.
        // Reschedule when the rate RISES.
        //
        // The wait is set when the previous meteor burns out, from the rate at
        // that moment — and the rate changes underneath it constantly. A shower's
        // radiant climbs all night, so the rate at 22:00 is a fraction of the
        // rate at 03:00; and at startup the schedule is made before the host has
        // pushed any shower in at all, from sporadics alone. Measured: the first
        // wait came out at 1096 seconds against a rate that wanted one a second.
        // Without this the busiest night of the year is as quiet as any other
        // until the twenty-minute sporadic gap happens to elapse.
        //
        // Only ever pulls the wait IN. Pushing it out would let a passing cloud
        // cancel a meteor that was already due.
        let gap = nextMeteorGap()
        if shootT - sec > gap * 2.5 { shootT = sec + gap }
        guard !shootActive, sec > shootT else { return }

        shootT = sec + nextMeteorGap()

        shootActive = true
        shootCount += 1
        shootT0 = sec
        // From the radiant when there is one — a shower's meteors come from a
        // point, and putting them anywhere else is the one mistake that makes a
        // shower not look like a shower. Scattered when there is not, because a
        // sporadic genuinely can come from anywhere.
        if meteorRadiantX >= 0, meteorRatePerHour > 1 {
            let spread = W * 0.22
            shootX = meteorRadiantX + (rnd() * 2 - 1) * spread
            shootY = meteorRadiantY + (rnd() * 2 - 1) * spread * 0.6
            shootX = max(W * 0.02, min(W * 0.9, shootX))
            shootY = max(H * 0.02, min(H * 0.6, shootY))
        } else {
            shootX = W * (0.1 + 0.5 * rnd())
            shootY = H * (0.06 + 0.18 * rnd())
        }
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
            // The wind carries spray off the lip: at 30 km/h across the screen
            // it is pushed a couple of cells downwind before it lands.
            let sideways = (rnd() * 2 - 1) * d.v * (0.45 + bounce * 0.5) + crossWind * 5
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
        case .widget, .window:  return Furniture.options.widgets
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
                let (melt, sublime) = Self.snowLoss(temp: t, uv: w.uv, wind: w.wind,
                                                    evap: evap, raining: w.rain > 0.1)
                f.snow = max(0, f.snow - dt * (melt + sublime))
                // What melts becomes water on the lip.
                // While it melts the lip under it stays wet and the meltwater
                // runs off and drips from the underside — a thaw you can see,
                // not snow quietly shrinking on a dry ledge.
                if melt > 0.00005 {
                    f.wet = min(1, max(f.wet, 0.30 + min(0.45, melt * 1800)))
                    f.runoff = min(1, f.runoff + dt * min(0.2, melt * 400))
                }
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
                f.snowSpan = max(0, f.snowSpan - dt * (melt * 0.8 + sublime * 0.6) / mass)
                if f.snowSpan <= 0.001 { f.snow = 0 }
            }
            if f.snow <= 0.001 { f.snowSpan = 0 }
            // Ice: only above zero, and slowly — a glaze survives a long thaw.
            if f.glaze > 0 && form != .freezingRain {
                let thaw = Self.glazeThaw(temp: t, uv: w.uv)
                f.glaze = max(0, f.glaze - dt * (thaw + 0.00002))
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
            // Wind drives the water on a lip toward its downwind end, so the
            // drips gather there rather than spreading evenly.
            let lean = max(-0.8, min(0.8, crossWind / 35))
            var along = rnd()
            if lean > 0 { along = 1 - pow(1 - along, 1 + lean * 2.5) }
            else if lean < 0 { along = pow(along, 1 - lean * 2.5) }
            drops.append(GlassDrop(x: s.left + along * s.w,
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
        updateLeaves(dt: dt, state: state)
        updateClumps(dt: dt)
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
        // DRAG: and wipes the wet film clean where it passes, like a wiper.
        if cursor.stir > 0.02, !trailCells.isEmpty {
            let R = SP * 3
            let c0 = max(0, Int((cursor.x - R) / SP)), c1 = min(cols - 1, Int((cursor.x + R) / SP))
            let r0 = max(0, Int((cursor.y - R) / SP)), r1 = min(rows - 1, Int((cursor.y + R) / SP))
            if c0 <= c1, r0 <= r1 {
                for cy in r0...r1 { for cx in c0...c1 {
                    trailCells[cy * cols + cx] *= 1 - min(1, cursor.stir * dt * 6)
                } }
            }
        }
        // The water standing along the bottom edge evaporates too. Nothing
        // took it away before: measured, a pool left by a shower was still
        // there after three hours of dry afternoon. Same physical rate as the
        // film — about twenty minutes to go in dry air, over an hour in humid.
        // Rings where the rain lands in the pool.
        for k in ripples.indices.reversed() {
            ripples[k].t += dt
            if ripples[k].t > 0.7 { ripples.remove(at: k) }
        }
        if wet && poolDepth > 0.3 && (form == .rain || form == .drizzle) && ripples.count < 24 {
            let n = rainIntensity * Float(cols) * 0.08 * dt
            if rnd() < n { ripples.append((x: rnd() * W, t: 0)) }
        }
        if !wet && poolDepth > 0 {
            poolDepth = max(0, poolDepth - dt * (0.00012 + w.evaporationRate * 0.0022))
        }
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
        // Signed: it used to be the wind's SPEED only, so every run on the
        // glass leaned right whichever way the wind blew.
        let windPush = Self.crossWind(w, facingAz: facingAz) / 90 * (gustFront ? 3.2 : 1)
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
            // ---- DRAG: a finger across the glass smears the water with it.
            if cursor.stir > 0.02 && d.ride < 0 {
                let ddx = d.x - cursor.x, ddy = d.y - cursor.y
                let R = SP * 4
                let dist = (ddx * ddx + ddy * ddy).squareRoot()
                if dist < R {
                    let k = cursor.stir * (1 - dist / R)
                    d.x += cursor.vx * dt * 0.55 * k
                    d.y += cursor.vy * dt * 0.55 * k
                    if !d.falling && k > 0.3 { d.falling = true }
                }
            }

            // ---- running along an edge
            //
            // Held on the top edge of the widget it met, moving toward the
            // nearer end (or downwind, when there is wind to speak of), shedding
            // a wet track as it goes. Past the end it drops off the corner and
            // carries on down the glass beside the widget — which is what makes
            // the water look like it met something rather than passed behind a
            // sticker.
            if d.ride >= 0 {
                if d.ride < surfaces.count {
                    let sf = surfaces[d.ride]
                    d.y = sf.top - d.r * 0.8
                    d.x += d.rideDir * (30 + 80 * min(1, d.r / (SP * 0.5))) * dt
                    d.r = max(d.r * (1 - dt * 0.04), SP * 0.06)
                    let cx = Int(d.x / SP), cy = Int(d.y / SP)
                    if cx >= 0, cx < cols, cy >= 0, cy < rows {
                        trailCells[cy * cols + cx] = min(1, trailCells[cy * cols + cx] + dt * 1.6)
                    }
                    if d.x < sf.left - d.r * 0.5 || d.x > sf.right + d.r * 0.5 {
                        d.x = d.rideDir < 0 ? sf.left - d.r * 1.1 : sf.right + d.r * 1.1
                        d.ride = -1
                        d.falling = true
                        d.v = 25
                    }
                } else {
                    d.ride = -1
                }
                drops[i] = d
                i -= 1
                continue
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
            //
            // A drop RUNNING down the glass is slow and held by it, so it does
            // not splash: it catches on the edge and runs along it (above). Only
            // a fast arrival throws spray. Anything too small to run — spray
            // fragments coming back down — is simply absorbed by the edge.
            if d.falling && d.splashLife == 0 && d.v > 4 {
                var handled = false
                let prevY = d.y - d.v * dt
                for k in 0..<surfaces.count
                    where surfaces[k].kind != .menuBar && surfaces[k].spans(d.x) {
                    guard prevY <= surfaces[k].top && d.y + d.r >= surfaces[k].top else { continue }
                    let sf = surfaces[k]
                    if d.r > SP * 0.12 && marks(sf.kind) {
                        if d.v > 320 && d.r > SP * 0.20 { splash(at: d, on: k) }
                        var nd = d
                        nd.ride = k
                        // Toward the nearer end, so an edge sheds from BOTH
                        // corners. Wind moves where the split falls rather than
                        // sending everything one way — a breeze sent every drop
                        // off the same corner and piled the water on one side.
                        let split = sf.left + sf.w * (0.5 - max(-0.35, min(0.35, windPush * 0.8)))
                        nd.rideDir = d.x < split ? -1 : 1
                        nd.v = 0
                        nd.y = sf.top - nd.r * 0.8
                        drops[i] = nd
                    } else {
                        drops.remove(at: i)
                    }
                    handled = true
                    break
                }
                if handled { i -= 1; continue }
            }

            // ---- nothing behind the furniture
            //
            // A widget is stuck to the glass. Beads, spray and condensation that
            // end up inside its outline are under it — and a translucent widget
            // showed them through itself, which is why the effects looked pasted
            // on top of the widgets instead of meeting them.
            if insideFurniture(d.x, d.y) { drops.remove(at: i); i -= 1; continue }

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
                    guard cx >= 0, cx < cols, cy >= 0, cy < rows,
                          !insideFurniture(xx, yy) else { continue }
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
        static let leaf: Float = 14     // a fallen leaf; its colour in z
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

        // Which surface is being drawn, for the wear under it. Water, ice
        // and frost thin on a path; snow does its own (below), and leaves are
        // moved off it rather than faded.
        var wearI = -1
        @inline(__always)
        func put(_ cx: Int, _ cy: Int, _ v: Float, _ kind: Float,
                 _ bx: Float = 0, _ by: Float = 0) {
            guard cx >= 0, cx < cols, cy >= 0, cy < rows else { return }
            var v = v
            if wearI >= 0, kind != Deposit.leaf, kind != Deposit.snow {
                let w = wearAt(wearI, cx)
                if w > 0.02 { v *= 1 - w * (kind == Deposit.glaze ? 0.5 : 0.75) }
            }
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
            wearI = i

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

            // ---- leaves, under the snow and over the water: a scatter along
            // the lip, some cells bare, each in its own autumn colour.
            // Each leaf in the cell it lies in, in its own colour and age; a
            // second in the same cell lies on top of the first. Nothing here
            // moves unless a leaf does.
            if !f.lying.isEmpty {
                if leafStack.count < cols { leafStack = [UInt8](repeating: 0, count: cols) }
                for cx in c0...c1 { leafStack[cx] = 0 }
                for l in f.lying {
                    let cx = max(c0, min(c1, leafCell(l, on: s)))
                    let d = Int(leafStack[cx])
                    guard d < 2 else { continue }
                    leafStack[cx] += 1
                    // One left lying on a path is trodden: flattened, soggy,
                    // browned well past its age.
                    put(cx, lipRow - d, d == 0 ? 0.78 : 0.68, Deposit.leaf,
                        Self.leafCode(hue: l.hue, age: l.age + wearAt(i, cx) * 10), 0)
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
                let half = span * 0.5 * f.snowSpan
                // The wind carries lying snow along the lip and banks it at the
                // downwind end — a drift, not a symmetric dome. The crown moves
                // off centre with the wind across the screen.
                let lean = max(-0.8, min(0.8, crossWind / 35))
                let mid = (Float(c0) + Float(c1) + 1) * 0.5 + lean * (span * 0.5 - half) * 0.5
                    + lean * half * 0.25
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
                    // Trodden down on a path, banked a little higher at its
                    // shoulders, where what was pushed aside went.
                    let wr = wearAt(i, cx)
                    let berm = max(0, max(wearAt(i, cx - 1), wearAt(i, cx + 1)) - wr) * 0.45
                    let deep = f.snow * prof * (1 - rough * g) * (1 - 0.85 * wr) + f.snow * berm
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
            // Rain landing in it: a ring that opens out across the surface
            // and fades, a cell or two wide — z carries how much it catches
            // the light (the shader's kind 5).
            let surface = max(0, Int(top.rounded(.down)))
            for r in ripples {
                let rad = r.t / 0.7 * 1.8
                let fade = max(0, 1 - r.t / 0.7)
                let c = r.x / SP
                for cx in max(0, Int(c - rad - 1))...min(cols - 1, Int(c + rad + 1)) {
                    let d = abs(Float(cx) + 0.5 - c)
                    let ring = max(0, 1 - abs(d - rad) * 1.6) * fade
                    guard ring > 0.05 else { continue }
                    for cy in surface..<min(rows, surface + 2) {
                        let idx = cy * cols + cx
                        if glassCells[idx].y == 5 { glassCells[idx].z = max(glassCells[idx].z, ring * (cy == surface ? 1 : 0.5)) }
                    }
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
        for c in clumps where !c.leaf {
            stamp(x: c.x, y: c.y, r: c.r, kind: Deposit.snow, strength: 0.95)
        }
        // A leaf is one tile in its colour (hue in z), wherever it is now.
        for c in clumps where c.leaf {
            let cx = Int(c.x / SP), cy = Int(c.y / SP)
            guard cx >= 0, cx < cols, cy >= 0, cy < rows else { continue }
            let idx = cy * cols + cx
            if glassCells[idx].x < 0.9 { glassCells[idx] = SIMD4<Float>(0.9, Deposit.leaf, Self.leafCode(hue: c.hue, age: c.age), 0) }
        }
        // Leaves lying along the bottom, a row or two deep where they pile.
        for cx in 0..<min(cols, groundLeaves.count) where groundLeaves[cx] > 0.06 {
            let v = groundLeaves[cx]
            let hue = jitter(Float(cx) * 4.7 + 1.3)
            let deep = v > 0.6 ? 2 : 1
            for k in 0..<deep {
                let idx = (rows - 1 - k) * cols + cx
                let a = min(0.9, 0.35 + v * 0.55) * (k == 0 ? 1 : 0.7)
                let age = cx < groundLeafAge.count ? groundLeafAge[cx] : 0
                if a > glassCells[idx].x { glassCells[idx] = SIMD4<Float>(a, Deposit.leaf, Self.leafCode(hue: (hue + Float(k) * 0.37).truncatingRemainder(dividingBy: 1), age: age), 0) }
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

        // Nothing on the glass inside a piece of furniture's outline: the
        // widget is stuck there, so water is around it, never under it. A
        // translucent widget otherwise shows the film through itself. The top
        // edge row stays — that is where water rides.
        for sf in surfaces where sf.kind != .menuBar {
            let c0 = max(0, Int((sf.left / SP).rounded(.up)))
            let c1 = min(cols - 1, Int((sf.right / SP).rounded(.down)) - 1)
            let r0 = max(0, Int((sf.top / SP).rounded(.up)))
            let r1 = min(rows - 1, Int((sf.bottom / SP).rounded(.down)) - 1)
            guard c0 <= c1, r0 <= r1 else { continue }
            for cy in r0...r1 { for cx in c0...c1 { glassCells[cy * cols + cx] = .zero } }
        }
    }
}
