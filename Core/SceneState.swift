//  SceneState.swift — the renderer's sole input.
//
//  Everything the mosaic needs to draw a frame lives here. Weather, F1 and
//  music are deferred, but they enter the engine by filling fields in this
//  struct — the renderer itself never changes shape to accommodate them.

import Foundation
import simd

// MARK: - GPU-facing uniforms
//
// Layout mirrors `struct Uniforms` in Scene.metal exactly. Every field is a
// 4-byte scalar and the tail is padded to 224 bytes, so there are no vector
// alignment rules to reason about on either side. If you add a field, add it
// in both places, in the SAME ORDER, and keep the total a multiple of 16.
// A mismatch does not crash — it silently shifts every field after the seam.

struct Uniforms {
    var cols: Float = 0, rows: Float = 0
    var pixW: Float = 0, pixH: Float = 0
    var cellSP: Float = 0
    var time: Float = 0
    var sunAlt: Float = 0, sunAz: Float = 0
    var moonAlt: Float = 0, moonAz: Float = 0, moonIllum: Float = 0, moonPhase: Float = 0
    var facingAz: Float = 0
    var covF: Float = 0
    var aqiF: Float = 0, smokeF: Float = 0
    var uv: Float = 0, wind: Float = 0, windDir: Float = 0
    var rain: Float = 0, snow: Float = 0, vis: Float = 0, humid: Float = 0
    var scAQI: Float = 0
    var code: Int32 = 0
    var kind: Int32 = 0
    var flashAmp: Float = 0
    var shootActive: Float = 0, shootX: Float = 0, shootY: Float = 0, shootT0: Float = 0
    var starCount: Int32 = 0
    var boltCount: Int32 = 0
    var shape: Int32 = 0
    var finish: Int32 = 0
    var posterQ: Float = 16
    var nightBoost: Float = 0
    var cbase: Float = 218
    var skyBrAmt: Float = 1
    var lowfx: Float = 0
    var glassWet: Float = 0
    var grime: Float = 0
    var steam: Float = 0
    var cloudLow: Float = 0, cloudMid: Float = 0, cloudHigh: Float = 0
    var fogOn: Float = 0
    // ---- relief block. Mirrored field-for-field in Scene.metal.
    var depthAmt: Float = 0
    var emphAmt: Float = 0
    var lightInt: Float = 0
    var refractAmt: Float = 0
    var dispersAmt: Float = 0
    var frostAmt: Float = 0
    var splayAmt: Float = 0
    // ---- what is falling, and how dark it has got. These two took over the
    // pair of tail pad floats, so the struct is still 56 fields / 224 bytes.
    /// `PrecipForm.rawValue` as a float. Snow, hail and drizzle are not one
    /// substance at three intensities, and the streak pass draws them apart.
    var pform: Float = 0
    /// `WeatherState.gloom`, 0..1. How much light the deck is taking out.
    var gloomF: Float = 0
    // ---- the second block of four, taking the struct from 224 to 240 bytes.
    /// `SurfaceWeather.dropDiameter`, mm. Inverted from the MEASURED fall speed,
    /// so it is what decides whether a sunlit shower gives a vivid spectral bow
    /// or a broad white fogbow.
    var dropMM: Float = 0
    /// Display headroom actually available right now: 1 means plain SDR, and
    /// anything above is how far past white this frame may go. Read from
    /// `NSScreen` every frame rather than assumed — see `WallpaperSurface`.
    var edrHead: Float = 1
    var pad0: Float = 0, pad1: Float = 0
}

struct GPUBreather { var ax, ay, R, per, s1, s2, ph, ph2: Float }
/// Raw horizontal coordinates. Screen position is computed in the shader
/// so the heading can move without reprojecting the catalog every frame.
struct GPUStar     { var alt, az, br, _p: Float }
struct GPUStreak   { var c, y, len, v: Float }
struct GPUBoltPt   { var x, y: Float }

// MARK: - Style

/// How the view decides which way it is looking.
enum HeadingMode: Int32, Codable, CaseIterable {
    /// A compass bearing you set. The sky drifts past it, and the sun spends
    /// part of the day out of frame — which is what really happens if you look
    /// out of one window.
    case custom = 0
    /// Follow whatever is up: the sun by day, the moon by night. The body stays
    /// centred, so it is always on screen, and the view pans between them.
    ///
    /// Latitude-independent by construction — it tracks whatever azimuth the
    /// body actually has, so it behaves the same in Reykjavik as in Singapore.
    case dynamic = 1

    var title: String {
        switch self {
        case .custom:  return "Custom heading"
        case .dynamic: return "Dynamic heading"
        }
    }
}

/// Two axes, so a new design is one branch in `presentPass` rather than a fork
/// of the engine. More shapes and finishes are expected.
enum MosaicShape: Int32, Codable, CaseIterable { case square = 0, dot = 1 }
enum MosaicFinish: Int32, Codable, CaseIterable { case glass = 0, flat = 1 }

// MARK: - Weather

/// How the precipitation is ORGANISED, which is most of what tells one wet day
/// from another out of a window.
///
/// Steady frontal rain and a scattered afternoon shower deliver the same
/// millimetres and look nothing alike: the first is uniform, grey and lasts for
/// hours; the second is cellular, arrives and leaves in minutes and has bright
/// gaps between the cells. The distinguishing variables are the ones the
/// meteorological literature uses to split stratiform from convective — updraft
/// strength (proxied by CAPE), drop size and rate, and above all whether the
/// precipitation is CONTINUOUS or INTERMITTENT in time.
///
///   Stratiform: weak updrafts (10^-2 – 10^-1 m/s), small precipitation
///   elements, long-lived, low intensity. Convective: 1–10 m/s updrafts, large
///   drops, localised, high intensity. (Houze, *Nimbostratus and the Separation
///   of Convective and Stratiform Precipitation*; UWyo notes on convective and
///   stratiform rain in the tropics.)
enum PrecipMorphology: Int32, Codable {
    case none = 0
    /// Very small drops, ~0.2–0.5mm, falling at 0.7–2 m/s. Uniform, dense,
    /// almost floating. From a low stratus deck, not a raining one.
    case drizzle = 1
    /// Nimbostratus. Uniform in space and continuous in time, hours long.
    case steady = 2
    /// Cellular and patchy — the user's "scattered rain". Cells a few km wide
    /// with genuinely dry gaps, so it starts and stops.
    case showery = 3
    /// A line. Banded and segmented, with a gust ahead of it, brief and violent.
    case squally = 4

    var title: String {
        switch self {
        case .none: return "none"
        case .drizzle: return "drizzle"
        case .steady: return "steady"
        case .showery: return "showery"
        case .squally: return "squally"
        }
    }
}

/// Where in the arc of an event we are. The user's own description of rain is a
/// SEQUENCE: "the grey clouds come over, then it gets dark, then it rains".
/// Lead and lag, not a state.
///
/// Warm front: cirrus 12–24h out, thickening to cirrostratus, then altostratus
/// with precipitation inside six hours, then nimbostratus and steady rain.
/// Airmass storm: towering cumulus, then precipitation at the surface roughly
/// twenty minutes later, whole cell over in thirty. Squall line: a dark shelf
/// and a gust front minutes ahead of the rain.
enum PrecipPhase: Int32, Codable {
    case clear = 0
    /// Deck is present and building, precipitation is over an hour out.
    case thickening = 1
    /// Minutes away. This is the "then it gets dark" step.
    case imminent = 2
    case active = 3
    /// Just stopped. The deck does not evaporate the moment the rain does.
    case clearing = 4

    var title: String {
        switch self {
        case .clear: return "clear"
        case .thickening: return "thickening"
        case .imminent: return "imminent"
        case .active: return "active"
        case .clearing: return "clearing"
        }
    }
}

/// What is physically falling. Distinct from morphology: a squall can drop
/// hail, a warm front can drop freezing rain.
enum PrecipForm: Int32, Codable {
    case none = 0, drizzle = 1, rain = 2, freezingRain = 3, icePellets = 4
    case snow = 5, snowGrains = 6, graupel = 7, hail = 8

    var title: String {
        switch self {
        case .none: return "none"
        case .drizzle: return "drizzle"
        case .rain: return "rain"
        case .freezingRain: return "freezing rain"
        case .icePellets: return "ice pellets"
        case .snow: return "snow"
        case .snowGrains: return "snow grains"
        case .graupel: return "graupel"
        case .hail: return "hail"
        }
    }
}

/// Which crystal is falling, which is what decides how snow MOVES.
///
/// The habit is set by the temperature (and, for branching, the supersaturation)
/// at which the crystal grew — the Nakaya diagram: plates near 0 to -4C,
/// needles and columns -4 to -10C, plates and then dendrites -10 to -22C,
/// columns again below that; higher supersaturation makes everything bigger and
/// more branched. Fall speed follows: measured velocity–diameter coefficients
/// are 0.82 m/s for dendrites, 0.74 for plates, 1.03 for needles and 1.30 for
/// graupel (Barthazy & Schefold 2006), with wet aggregates near 0C reaching
/// 1.5–1.8 m/s. A dendrite at 0.8 m/s in any breeze at all does not fall, it
/// drifts and flutters; graupel goes almost straight down.
enum SnowHabit: Int32, Codable {
    case none = 0
    /// Melting aggregates near 0C. Big, wet, fast for snow, splat on the glass.
    case wetAggregate = 1
    /// 0 to -4C. Small, simple, unremarkable.
    case plate = 2
    /// -4 to -10C. Slender, falls comparatively fast and straight.
    case needle = 3
    /// -10 to -22C, needs supersaturation. The classic star. Slowest, flutters.
    case dendrite = 4
    /// Below about -22C, and diamond dust. Tiny, sparse, sharp.
    case columnar = 5
    /// Rimed. Only forms where there is supercooled water, i.e. convection.
    case graupel = 6

    var title: String {
        switch self {
        case .none: return "none"
        case .wetAggregate: return "wet aggregate"
        case .plate: return "plate"
        case .needle: return "needle"
        case .dendrite: return "dendrite"
        case .columnar: return "columnar"
        case .graupel: return "graupel"
        }
    }
}

/// What is dimming the horizontal view. These are three different substances
/// and they do not look alike: fog and mist are water droplets and are white
/// and neutral, haze and dust are dry aerosol and are brown or yellow.
///
/// The line between them is drawn where aviation draws it — fog below 1000m
/// visibility, mist from 1000 to 5000m with humidity above 80%, haze the same
/// visibility range in DRIER air.
enum Obscuration: Int32, Codable {
    case none = 0, haze = 1, mist = 2, fog = 3

    var title: String {
        switch self {
        case .none: return "none"
        case .haze: return "haze"
        case .mist: return "mist"
        case .fog: return "fog"
        }
    }
}

@inline(__always) private func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }
@inline(__always) private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * clamp01(t) }

/// Mirrors `scKind` in roomstand.py. Cloud/rain behaviour keys off this.
enum SceneKind: Int32, Codable {
    case sun = 0, partly = 1, cloud = 2, rain = 3, snow = 4, thunder = 5

    // The per-condition deck brightness table that used to live here
    // (roomstand.py:2387 — thunder 82, rain 110, snow 205, cloud 170, sun and
    // partly 218) is gone. Its only reader was `continuousCloudBase`, which now
    // derives the same quantity from measured light transmission; see the note
    // there. A table indexed by a WMO code cannot answer "how bright is this
    // deck", because two skies with the same measured transmission are the same
    // brightness whichever bucket their code fell into.

    var isWet: Bool { self == .rain || self == .thunder || self == .snow }

    /// WMO code -> kind, matching `wxCat` in roomstand.py:1256.
    static func from(code: Int) -> SceneKind {
        switch code {
        case 0, 1:            return .sun
        case 2:               return .partly
        case 3, 45, 48:       return .cloud
        case 71...77, 85, 86: return .snow
        case 95...99:         return .thunder
        case 51...67, 80...82: return .rain
        default:              return .partly
        }
    }
}

/// Live conditions — everything the forecast will tell us, because the engine
/// draws better the more it knows. Defaults describe a clear, calm day, so the
/// scene renders correctly with no weather source attached.
///
/// `Equatable` so the renderer can tell a NEW READING from a re-assignment of
/// the one it already has — see `WeatherEaser`. Every stored property is a
/// scalar, an optional scalar or an optional `Date`/`String`, so the synthesised
/// `==` is exactly the right test and costs nothing worth measuring.
struct WeatherState: Equatable, Codable {

    // ---- what it is
    var code: Int = 0
    var kind: SceneKind = .sun
    var isDay: Bool = true

    // ---- cloud, by layer.
    // A single "cloud cover" number cannot tell high cirrus from a low
    // overcast, and they look nothing like each other. Splitting the deck by
    // altitude is the single biggest realism gain available from this data.
    var cover: Float = 5          // % total
    var cloudLow: Float = 0       // % below ~2km — the dense, dark deck
    var cloudMid: Float = 0       // % 2-6km
    var cloudHigh: Float = 0      // % above ~6km — thin, bright, wispy

    // ---- air
    var temperature: Float = 20   // °C
    var apparent: Float = 20
    var dewPoint: Float = 10
    var humidity: Float = 50      // %
    var pressureMSL: Float = 1013 // hPa
    var surfacePressure: Float = 1013

    // ---- wind
    var wind: Float = 6           // km/h sustained
    var gusts: Float = 6          // km/h peak
    var windDir: Float = 180      // degrees, direction it comes FROM

    // ---- water
    var precipitation: Float = 0  // mm, all forms
    var rain: Float = 0           // mm
    var showers: Float = 0        // mm — convective, burstier than steady rain
    var snow: Float = 0           // cm
    var snowDepth: Float = 0      // m lying
    var precipProbability: Float = 0

    // ---- light and sight
    var visibility: Float = 12000 // m
    var uv: Float = 3

    // ---- convection.
    // These are what make a storm behave like a storm: CAPE is the energy
    // available to an updraft, lifted index how unstable the column is, and
    // together they set how often it flashes rather than a fixed timer.
    var cape: Float = 0           // J/kg
    var liftedIndex: Float = 0    // negative = unstable
    var convectiveInhibition: Float = 0
    var freezingLevel: Float = 3000   // m
    var boundaryLayer: Float = 800    // m

    // ---- air quality
    var aqi: Float = 30
    var pm25: Float = 0
    var pm10: Float = 0
    var smoke: Float = 0          // 0..1 wildfire aerosol score

    // ---- the nowcast timeline, summarised.
    //
    // Open-Meteo's `minutely_15` block is a measured-quantity forecast in
    // millimetres per quarter hour, not a classification, so it is safe to lean
    // on in a way the WMO code is not. Two hours behind and up to four hours
    // ahead of now are fetched and reduced to these scalars in Weather.swift —
    // the arrays themselves are not kept, because WeatherState is copied every
    // frame.
    //
    // The important one is `nowcastRuns`. Precipitation that is CONTINUOUS
    // across the window is stratiform; precipitation that comes in two or three
    // separate bursts with dry slots between them is cellular, and that is a
    // direct measurement of the thing the user called "scattered rain" rather
    // than an inference from a code.
    var nowcastSlots: Int = 0          // usable slots in the window; 0 = no nowcast
    var nowcastWetSlots: Int = 0       // of those, how many had >= 0.05mm
    var nowcastRuns: Int = 0           // contiguous wet runs (1 = one long event)
    var minutesToPrecip: Float = -1    // until the next wet slot; -1 = none in window
    var minutesSincePrecip: Float = -1 // since the last one; -1 = none in window
    var precipNext60: Float = 0        // mm summed over the next four slots
    var precipPast60: Float = 0        // mm summed over the previous four

    /// How long the accumulation in `precipitation` covers, minutes. The hourly
    /// feed reports an hour; the 15-minute nowcast, when it overrides, reports a
    /// quarter of one. Without this the same number means two different rates.
    var precipWindow: Float = 60

    // ---- hourly trend, over the next three hours. Cloud thickening and
    // pressure falling are what a front looks like BEFORE it arrives.
    var coverTrend: Float = 0          // % change in total cover
    var lowTrend: Float = 0            // % change in low cover
    var pressureTrend: Float = 0       // hPa; negative = falling = front nearing
    var temperatureTrend: Float = 0    // °C
    var capeTrend: Float = 0           // J/kg
    var hasTrend: Bool = false

    /// Height of the lowest broken-or-overcast layer, metres AGL. Measured, from
    /// a METAR; -1 when nothing has reported one. A low ceiling under rain is a
    /// deep deck and a genuinely dark room.
    var ceiling: Float = -1

    // MARK: Derived

    /// Total liquid falling, in mm — showers are convective and burstier than
    /// steady rain, so they count for more.
    var effectiveRain: Float { rain + showers * 1.25 }

    // MARK: Observed, not modelled
    //
    // Set by `reconcile(with:)` from a nearby METAR. A METAR is not a forecast:
    // it is a report of what is happening at a known point right now. Where one
    // is available it outranks anything derived from the model, because the
    // model's job is to predict and this thing's job is to look correct out of
    // the window.
    //
    // Optional on purpose. `nil` means no usable station, which is different
    // from "a station reported nothing" — the first falls back to the model,
    // the second overrules it.
    var observedThunder: Bool? = nil
    var observedFog: Bool? = nil
    /// When the report was taken, and by whom. Diagnostics and staleness.
    var observedAt: Date? = nil
    var observedFrom: String? = nil

    // The METAR present-weather vocabulary already distinguishes exactly the
    // things this file is trying to derive. SHRA is a rain SHOWER — cellular,
    // convective — where RA is continuous rain, and DZ is drizzle. An observer
    // has separated stratiform from convective for us, at a known point, right
    // now. Nothing derived from CAPE can outrank that, so where these are
    // present they decide the morphology outright.
    var observedShowery: Bool? = nil      // SH descriptor
    var observedDrizzle: Bool? = nil      // DZ
    var observedContinuous: Bool? = nil   // RA/SN with no SH descriptor
    var observedFreezing: Bool? = nil     // FZRA / FZDZ
    var observedHail: Bool? = nil         // GR (hail) or GS (small hail/graupel)
    var observedIcePellets: Bool? = nil   // PL
    var observedBlowingSnow: Bool? = nil  // BLSN / DRSN
    var observedSquall: Bool? = nil       // SQ
    var observedMist: Bool? = nil         // BR — water droplets, 1–5km
    var observedDryHaze: Bool? = nil      // HZ / FU / DU / SA — dry aerosol
    /// Something is visibly going on nearby but not here — VCSH, VCTS. This is
    /// the honest reading of a shower you can see across the valley.
    var observedVicinity: Bool? = nil

    /// Set by the on-device calibration when there is no live observation to
    /// defer to. Deliberately separate from `observedThunder`: one is a report
    /// that thunder was or was not heard, the other is a learned expectation,
    /// and conflating them would let a fit outrank an observer.
    var calibratedThunder: Bool? = nil
    var calibratedFrom: String? = nil

    /// Whether an observation is still worth deferring to. Reports come every
    /// half hour; past ninety minutes we are back to trusting the model.
    var hasFreshObservation: Bool {
        guard let t = observedAt else { return false }
        return Date().timeIntervalSince(t) < 90 * 60
    }

    // MARK: What the sky is ACTUALLY doing
    //
    // The single most important rule in here: trust the MEASUREMENT, not the
    // WMO code. The code is a lagging classification of a wider area — it will
    // happily report "drizzle" with 0.0mm measured, and it does so often. Two
    // separate bugs came from believing it:
    //
    //   * rain drawn on a dry day because the code said 51
    //   * lightning all day because CAPE alone was allowed to trigger it, and
    //     monsoon Noida sits at 2000-4000 J/kg with a perfectly quiet sky
    //
    // Everything downstream now keys off these, never off `code` directly.

    /// Water genuinely arriving, in mm. Snow is weighted to a liquid
    /// equivalent so one threshold works for both.
    ///
    /// `snow` is reported in CENTIMETRES of depth and the conventional
    /// snow-to-liquid ratio is about ten to one, so a centimetre of snow is
    /// about a millimetre of water and the conversion is times one, not times
    /// ten. The old factor made every snowfall behave as ten times the weather
    /// it was: two centimetres an hour — heavy but ordinary — came out as a
    /// 20mm/h rate, which drove the fall speed, the streak length and the
    /// through-precipitation visibility right off their curves and reported a
    /// hundred-metre whiteout for a normal snowy afternoon. Every published
    /// relationship downstream (Gunn & Kinzer, Rasmussen) is written against a
    /// liquid-equivalent rate, so this has to be one.
    var precipAmount: Float { max(precipitation, effectiveRain + snow) }

    /// Is anything actually falling? A hair above zero, because the feeds
    /// report 0.01mm noise on dry days.
    var isPrecipitating: Bool { precipAmount >= 0.05 }

    /// Fog is observed far more reliably than it is modelled — visibility in a
    /// model is a grid-box average, and fog is famously not.
    ///
    /// Now routed through `obscuration`, which separates fog from mist: a METAR
    /// reporting BR at five kilometres was previously drawn as full fog, and
    /// five kilometres of visibility is a slightly soft horizon, not a whiteout.
    var isFoggy: Bool { obscuration == .fog }

    /// A thunderstorm requires the code to SAY thunderstorm. CAPE is stored
    /// energy, not a storm — it says the atmosphere could produce one, which is
    /// true most summer afternoons in the subtropics and means nothing on its
    /// own.
    var isThundering: Bool {
        // An observer within range of the station either heard thunder or did
        // not. That settles it, in both directions — this is what stops a wall
        // of monsoon CAPE and an optimistic WMO code from putting lightning
        // over a quiet evening.
        if hasFreshObservation, let obs = observedThunder { return obs }
        // Nothing live. Fall back to what this location has taught us about
        // what the model's thunder codes actually mean here.
        if let learned = calibratedThunder { return learned }
        return code >= 95 && code <= 99
    }

    /// What to draw, derived from measurements rather than the reported code.
    /// If the feed claims rain and nothing is falling, this correctly reads as
    /// cloud — which is what you would see out of the window.
    var effectiveKind: SceneKind {
        if isThundering { return .thunder }
        if snow >= 0.05 { return .snow }
        if isPrecipitating { return .rain }
        if cover >= 70 { return .cloud }
        if cover >= 25 { return .partly }
        return .sun
    }

    /// How much water is arriving, 0..1. Drives the whole glass layer.
    var rainIntensity: Float {
        min(1, effectiveRain / 5 + snow / 4)
    }

    /// Spread between sustained wind and gusts, 0..1. A gusty day should not
    /// look like a steady one at the same mean speed.
    var gustiness: Float {
        guard wind > 0.5 else { return 0 }
        return max(0, min(1, (gusts - wind) / max(wind, 8)))
    }

    /// How close the air is to saturation. Small spread means fog, mist and a
    /// pane that will not dry.
    var dewSpread: Float { temperature - dewPoint }

    /// Likelihood the air itself is fogging, independent of the WMO code —
    /// which reports fog only once it is already established.
    var fogginess: Float {
        let bySpread = max(0, 1 - dewSpread / 3)
        let byVis = max(0, 1 - visibility / 4000)
        return min(1, max(bySpread * 0.7, byVis))
    }

    /// Storm energy, 0..1, from CAPE and instability together. This is what
    /// paces the lightning: 0 means no electrical activity at all.
    var convectiveEnergy: Float {
        // Gated on the code, NOT on CAPE. CAPE then sets how active the storm
        // is once one is genuinely reported.
        guard isThundering else { return 0 }
        let byCape = min(1, cape / 2500)
        let byLI = min(1, max(0, -liftedIndex) / 8)
        return min(1, byCape * 0.65 + byLI * 0.35)
    }

    /// Saturation vapour pressure in kPa (Tetens). The amount of water the air
    /// could hold at this temperature.
    private func saturationVapourPressure(_ t: Float) -> Float {
        0.61078 * exp(17.27 * t / (t + 237.3))
    }

    /// Vapour pressure deficit, kPa — how thirsty the air is. Computed from the
    /// dew point, which is the honest measure: the gap between what the air
    /// holds and what it could hold is what actually drives evaporation.
    var vapourPressureDeficit: Float {
        max(0, saturationVapourPressure(temperature) - saturationVapourPressure(dewPoint))
    }

    /// How fast water leaves the pane, 0..1 in arbitrary but physical
    /// proportions. Evaporation rises with the vapour pressure deficit, is
    /// accelerated by wind carrying the boundary layer away, and by solar
    /// energy at the surface. Rain suppresses it outright.
    ///
    /// This replaces a flat decay constant, which is why the glass used to fill
    /// up and never clear: at 87% humidity real water genuinely does not dry,
    /// but on a bright dry day it should be gone in minutes.
    var evaporationRate: Float {
        guard rainIntensity < 0.02 else { return 0.02 }      // still raining
        let vpd = min(3.0, vapourPressureDeficit)            // kPa, ~0-3 typical
        let windFactor = 1 + min(2.5, wind / 18)             // forced convection
        let sunFactor = 1 + min(1.6, uv / 6)                 // radiative input
        return min(1, vpd / 3 * 0.55 * windFactor * sunFactor)
    }

    /// Falling snow rather than rain, from the freezing level rather than the
    /// code alone — a freezing level near the ground means sleet or snow even
    /// when the code says rain.
    var frozenFraction: Float {
        if snow > 0 { return 1 }
        guard freezingLevel < 900 else { return 0 }
        return min(1, (900 - freezingLevel) / 600)
    }

    // MARK: - How it PRESENTS
    //
    // Everything below this line answers "what would this look like out of the
    // window", not "what category is this". The rules are the same two that got
    // the engine out of trouble the first time:
    //
    //   1. A measurement outranks a classification. Every branch here is gated
    //      on a number somebody measured — millimetres, metres of visibility,
    //      km/h of gust, a METAR present-weather group — and never on a WMO
    //      code or a CAPE value alone.
    //   2. Missing data degrades to the calmer answer. If the nowcast is
    //      absent, morphology falls back to the model's own split of rain
    //      against showers, and then to `steady`, which is the least dramatic
    //      thing it could be.

    /// Only trust an observed flag while the report behind it is fresh.
    private func obs(_ v: Bool?) -> Bool? { hasFreshObservation ? v : nil }

    /// Precipitation rate in mm/h, with the accumulation window accounted for.
    /// This is the number the fall-speed and darkening curves below are written
    /// against, because every published relationship is per hour.
    var precipRate: Float {
        let scaled = precipAmount * (60 / max(15, precipWindow))
        // The nowcast's own totals are a second opinion on the same quantity and
        // are already per hour. Take the larger: a slot boundary can put a burst
        // just outside the current window.
        return max(scaled, max(precipPast60, precipNext60 * 0.75))
    }

    /// Of the liquid falling, how much the model files as convective showers
    /// rather than as rain. 0 when nothing is falling.
    var showerFraction: Float {
        let total = rain + showers
        guard total > 0.01 else { return 0 }
        return clamp01(showers / total)
    }

    /// Fraction of the nowcast window that is wet. 1 means it never stopped.
    /// nil when there is no nowcast to measure.
    var nowcastWetFraction: Float? {
        guard nowcastSlots >= 6 else { return nil }
        return Float(nowcastWetSlots) / Float(nowcastSlots)
    }

    // MARK: Morphology

    /// How the precipitation is organised. See `PrecipMorphology`.
    ///
    /// The ladder is ordered by how much the evidence is worth: an observer's
    /// present-weather group first, then the measured time structure of the
    /// nowcast, then the model's own convective/stratiform split, then physics.
    var morphology: PrecipMorphology {
        guard isPrecipitating else { return .none }
        let rate = precipRate
        let gustFactor = gustiness

        // ---- 1. an observer has already classified it.
        if let sq = obs(observedSquall), sq { return .squally }
        if let dz = obs(observedDrizzle), dz, rate < 1.5,
           obs(observedShowery) != true { return .drizzle }
        if let sh = obs(observedShowery), sh {
            return isSquallish(rate: rate, gust: gustFactor) ? .squally : .showery
        }
        if let cont = obs(observedContinuous), cont, obs(observedShowery) == false {
            // Continuous rain reported. Drizzle is still possible underneath it
            // if the rate is tiny and the deck is low — but never a shower.
            return isDrizzly(rate: rate) ? .drizzle : .steady
        }

        // ---- 2. the measured time structure of the nowcast.
        //
        // Two or more separate wet runs in a four-hour window, with dry slots
        // between them, IS scattered precipitation. One unbroken run covering
        // most of the window is frontal. This is a measurement of millimetres
        // against time, not a classification.
        if let wetFrac = nowcastWetFraction {
            if nowcastRuns >= 2 && wetFrac < 0.75 {
                return isSquallish(rate: rate, gust: gustFactor) ? .squally : .showery
            }
            if nowcastRuns <= 1 && wetFrac >= 0.7 {
                return isDrizzly(rate: rate) ? .drizzle : .steady
            }
        }

        // ---- 3. the model's own split. `showers` is the convective bucket;
        // it is a quantity in millimetres, so this is still a measurement.
        // CAPE is allowed to CORROBORATE here but not to assert on its own.
        if showerFraction > 0.6 && (cape > 300 || liftedIndex < -1) {
            return isSquallish(rate: rate, gust: gustFactor) ? .squally : .showery
        }

        // ---- 4. physics. Drizzle falls out of a shallow low deck in nearly
        // saturated air with no instability underneath it.
        if isDrizzly(rate: rate) { return .drizzle }

        return .steady
    }

    /// Drizzle is defined by what it is NOT: not much water, out of low cloud
    /// only, in air close to saturation, with no convection anywhere in it.
    /// 0.2–0.5mm drops falling at well under 2 m/s.
    private func isDrizzly(rate: Float) -> Bool {
        guard snow < 0.05 else { return false }
        guard rate <= 0.9 else { return false }              // ~drizzle rates
        guard cloudLow >= 55, cloudMid < 60 else { return false }
        guard cape < 300 else { return false }
        // Near saturation: drizzle comes with a damp, close, low sky.
        guard dewSpread < 4 || humidity >= 88 else { return false }
        // A high ceiling is not drizzle, whatever the rate. Only tested when a
        // station actually measured one.
        if ceiling >= 0 && ceiling > 1500 { return false }
        return true
    }

    /// A squall is a line, not a cell: violent, brief, and announced by wind.
    /// Requires a MEASURED gust spread and a MEASURED rate — never CAPE alone,
    /// which is the mistake that once put lightning over a quiet evening.
    private func isSquallish(rate: Float, gust: Float) -> Bool {
        guard rate >= 3 else { return false }
        guard gusts >= 35 else { return false }
        guard gust >= 0.45 else { return false }
        // And something has to corroborate that this is convective, not just a
        // windy frontal band.
        return isThundering || obs(observedHail) == true || showerFraction > 0.5
    }

    // MARK: Phase — the sequence, with its lead and its lag

    /// Where in the arc of the event we are.
    ///
    /// The lead time comes from the nowcast's millimetres, not from the
    /// probability field and not from the code. Where there is no nowcast this
    /// is deliberately capped at `thickening`: without a measured quantity in a
    /// future slot, the engine is allowed to darken a deck that is genuinely
    /// there, and is not allowed to claim rain is minutes away.
    var precipPhase: PrecipPhase {
        if isPrecipitating { return .active }
        if nowcastSlots > 0 {
            let to = minutesToPrecip
            if to >= 0 && to <= 35 { return .imminent }
            let since = minutesSincePrecip
            if since >= 0 && since <= 75 { return .clearing }
            if to > 35 && to <= 180 && cloudLow >= 40 { return .thickening }
            return .clear
        }
        // No nowcast. Fall back on the deck actually being there and the
        // pressure actually falling — both measured — plus the probability
        // field as a weak third vote.
        if hasTrend && cloudLow >= 55 && pressureTrend <= -1.0
            && precipProbability >= 55 && (coverTrend > 0 || lowTrend > 0) {
            return .thickening
        }
        return .clear
    }

    /// 0 while nothing is coming, rising to 1 at the moment precipitation
    /// starts. This is the "grey clouds come over, then it gets dark, THEN it
    /// rains" ramp — it leads the rain by up to two hours.
    ///
    /// Gated on cloud that is measurably present: an approach signal over a
    /// clear sky would darken nothing, and should not try to.
    var approachProgress: Float {
        guard !isPrecipitating else { return 1 }
        let deck = clamp01((max(cloudLow, cloudMid * 0.7) - 30) / 50)
        guard deck > 0 else { return 0 }
        if nowcastSlots > 0, minutesToPrecip >= 0 {
            return deck * clamp01(1 - minutesToPrecip / 120)
        }
        guard hasTrend else { return 0 }
        // Without a measured future quantity the ramp is capped at half, so a
        // falling barometer can grey the sky but can never fully stage a storm.
        let byPressure = clamp01(-pressureTrend / 4)
        let byProb = clamp01((precipProbability - 40) / 50)
        return deck * min(0.5, byPressure * 0.6 + byProb * 0.4)
    }

    /// The other end of the sequence. 1 the moment the rain stops, decaying
    /// over the following hour or so — the deck, the wet ground and the gloom
    /// all outlast the precipitation.
    var clearingProgress: Float {
        guard !isPrecipitating else { return 0 }
        guard nowcastSlots > 0, minutesSincePrecip >= 0 else { return 0 }
        return clamp01(1 - minutesSincePrecip / 90)
    }

    // MARK: Form and fall

    /// What is physically falling.
    var precipForm: PrecipForm {
        guard isPrecipitating else { return .none }

        // Observations first, in order of how unmistakable they are.
        if obs(observedHail) == true {
            // GR is hail proper; GS is small hail or graupel, and which one is
            // decided by whether the air can hold liquid at all.
            return temperature <= 2 ? .graupel : .hail
        }
        if obs(observedIcePellets) == true { return .icePellets }
        if obs(observedFreezing) == true { return .freezingRain }

        let frozen = frozenFraction
        if frozen > 0.5 || snow >= 0.05 {
            // Snow grains are the frozen equivalent of drizzle: tiny, sparse,
            // out of a shallow low deck.
            if code == 77 && precipRate < 0.6 { return .snowGrains }
            if snowHabit == .graupel { return .graupel }
            return .snow
        }

        // Liquid reaching a sub-freezing surface. This is a temperature
        // measurement plus a measured liquid rate, not a code lookup.
        if temperature <= 0.5 && frozen < 0.5 && precipRate > 0 {
            // A deep warm layer aloft over a shallow cold surface layer gives
            // freezing rain; a shallow warm nose over a deep cold layer
            // refreezes the drops into pellets before they land. The freezing
            // level is the only handle on that depth we have.
            return freezingLevel > 900 ? .freezingRain : .icePellets
        }

        if morphology == .drizzle { return .drizzle }
        return .rain
    }

    /// Which crystal, and therefore how it moves. See `SnowHabit`.
    var snowHabit: SnowHabit {
        guard frozenFraction > 0.4 || snow >= 0.05 else { return .none }

        // Riming needs supercooled water, which needs an updraft. Observed
        // small hail settles it; otherwise convection has to be corroborated by
        // measured shower structure, not by CAPE on its own.
        if obs(observedHail) == true && temperature <= 2 { return .graupel }
        if temperature > -10 && temperature < 2
            && (morphology == .showery || morphology == .squally)
            && cape > 200 && precipRate >= 1.5 { return .graupel }

        // The habit diagram, read at the surface temperature. This is a proxy:
        // the crystal grew somewhere in the cloud, not at the thermometer. It
        // is the right proxy for how the flake ARRIVES, which is what gets
        // drawn — a dendrite falling through air above freezing is a wet
        // aggregate by the time it reaches the window.
        let t = temperature
        if t > 0.5 { return .wetAggregate }
        if t > -3.5 { return .plate }
        if t > -10 {
            // Needles and columns. Above about 90% humidity they aggregate into
            // something closer to a wet flake.
            return humidity >= 92 ? .wetAggregate : .needle
        }
        if t > -22 {
            // The dendritic growth zone, but branching needs supersaturation.
            // Dry air here gives plain plates, which fall differently.
            return (humidity >= 80 || precipRate >= 0.5) ? .dendrite : .plate
        }
        return .columnar
    }

    /// Terminal fall speed in metres per second.
    ///
    /// Liquid follows Gunn & Kinzer (1949), still the reference measurement:
    /// 0.2mm drizzle at 0.72 m/s, 2.0mm rain at 6.49 m/s, 5.0mm at 9.09 m/s.
    /// Drop size grows with rate, so the curve below is written against rate and
    /// lands on those anchors. Snow follows the measured habit coefficients:
    /// 0.74 plate, 0.82 dendrite, 1.03 needle, 1.30 graupel (Barthazy & Schefold
    /// 2006), with wet aggregates faster and rimed graupel faster again.
    var fallSpeed: Float {
        let rate = precipRate
        switch precipForm {
        case .none:
            return 0
        case .drizzle:
            return 1.2
        case .snowGrains:
            return 0.8
        case .icePellets:
            // Small, dense, spherical. Falls far faster than snow and dead
            // straight, and bounces.
            return 3.6
        case .hail:
            return 14
        case .graupel:
            return 1.8 + min(1.2, rate * 0.2)
        case .snow:
            let base: Float
            switch snowHabit {
            case .wetAggregate: base = 1.45
            case .plate:        base = 0.74
            case .needle:       base = 1.03
            case .dendrite:     base = 0.82
            case .columnar:     base = 0.55
            case .graupel:      base = 1.80
            case .none:         base = 1.0
            }
            // Heavier snowfall means bigger aggregates, which fall faster.
            return base * (0.85 + min(0.5, rate * 0.12))
        case .rain, .freezingRain:
            // 2.5 m/s at a trace, 5.7 at 2mm/h, 7.6 at 10mm/h, 8.4 at 30mm/h.
            return 2.5 + 6.4 * sqrt(rate / (rate + 6))
        }
    }

    /// How long a falling streak reads, 0..1 relative — the product of how fast
    /// it falls and how much of it there is. Snow barely streaks at all; heavy
    /// rain is nearly continuous lines.
    var streakLength: Float {
        guard isPrecipitating else { return 0 }
        let bySpeed = clamp01((fallSpeed - 0.6) / 8)
        let byRate = clamp01(precipRate / 12)
        return clamp01(bySpeed * 0.7 + byRate * 0.3)
    }

    /// Sideways wander, 0..1. A slow flake in moving air does not fall, it
    /// flutters — the ratio of the wind to the fall speed is the whole story,
    /// and dendrites at 0.8 m/s in a 15 km/h breeze go almost sideways. Rain at
    /// 7 m/s in the same breeze barely leans.
    var flutter: Float {
        guard isPrecipitating, fallSpeed > 0.05 else { return 0 }
        let windMS = wind / 3.6
        let ratio = windMS / fallSpeed
        // Habit adds its own tumble: a branched crystal is unstable in a way a
        // sphere is not.
        let habitBonus: Float
        switch snowHabit {
        case .dendrite: habitBonus = 0.35
        case .plate:    habitBonus = 0.25
        case .wetAggregate, .needle: habitBonus = 0.12
        default:        habitBonus = 0
        }
        return clamp01(min(1.6, ratio) / 1.6 * 0.75 + habitBonus * clamp01(ratio * 2))
    }

    /// How clumpy the precipitation is across the frame, 0 uniform to 1 cellular.
    /// This is the "scattered" in scattered rain: real gaps, not just noise.
    var patchiness: Float {
        guard isPrecipitating else { return 0 }
        let base: Float
        switch morphology {
        case .none:     return 0
        case .drizzle:  base = 0.05      // drizzle is the most uniform thing there is
        case .steady:   base = 0.15
        case .showery:  base = 0.70
        case .squally:  base = 0.45      // banded rather than blotchy
        }
        // Corroborate with the measured dry fraction of the window, where there
        // is one — genuinely intermittent precipitation is patchier in space too.
        guard let wetFrac = nowcastWetFraction else { return base }
        return clamp01(base * 0.65 + (1 - wetFrac) * 0.55)
    }

    /// How organised into lines it is, 0..1. The user's "segmented rain".
    /// Only a squall line really does this, and only while the wind says so.
    var bandedness: Float {
        guard morphology == .squally else {
            // A gusty shower band gets a trace of it.
            return morphology == .showery ? clamp01(gustiness * 0.3) : 0
        }
        return clamp01(0.45 + gustiness * 0.4 + clamp01(precipRate / 20) * 0.15)
    }

    // MARK: Light

    /// Fraction of the clear-sky illuminance that reaches the ground, 0..1.
    ///
    /// Anchored on measured daylight: roughly 100,000 lux in full sun, 10,000 to
    /// 25,000 under a plain overcast, and about 1,000 on a very dark stormy day
    /// — so a raining deck is around a tenth of clear and a heavy storm around a
    /// fiftieth. Built as a product of per-layer transmissions, because that is
    /// how the atmosphere actually does it: thin cirrus takes about a fifth,
    /// altostratus about half (the sun still visible as through ground glass),
    /// a low overcast about three quarters.
    ///
    /// Precipitation then deepens the low deck. Nimbostratus is 4–6km thick and
    /// the sun is never visible through it; the rate is the best available proxy
    /// for that depth.
    var lightTransmission: Float {
        let hi = clamp01(cloudHigh / 100)
        let mid = clamp01(cloudMid / 100)
        let lo = clamp01(cloudLow / 100)
        var t = (1 - 0.20 * hi) * (1 - 0.50 * mid) * (1 - 0.75 * lo)

        // A raining deck. 2mm/h takes an overcast from ~0.25 to ~0.10; 10mm/h
        // to ~0.03, which is the "streetlights come on at noon" case.
        if isPrecipitating {
            t /= (1 + 0.75 * min(30, precipRate))
            // A convective deck is deeper than a frontal one at the same rate —
            // a cumulonimbus is opaque from 40,000ft down.
            if morphology == .squally || isThundering { t *= 0.65 }
        } else if approachProgress > 0 {
            // The lead. The deck thickens before the first drop, so the room
            // darkens first — which is the order the user actually described.
            t *= (1 - 0.35 * approachProgress)
        } else if clearingProgress > 0 {
            t *= (1 - 0.25 * clearingProgress)
        }

        // A MEASURED cloud base. This is the single most useful number a METAR
        // carries that the model does not report at all, and cloud base height
        // is most of what decides whether an overcast reads as a high grey lid
        // or a low oppressive one.
        //
        // It applies wet or dry. The old test only looked at the ceiling while
        // it was raining, which threw away the commonest case there is: a 200m
        // ceiling on a dry winter afternoon is the darkest sky most people ever
        // stand under. Scaled by how much low cloud is actually there, so a
        // ceiling reported under a broken sky cannot black out a half-clear
        // frame, and by construction a missing ceiling (-1) changes nothing.
        if ceiling >= 0 {
            let deck = clamp01(cloudLow / 100)
            let low = 1 - clamp01((ceiling - 120) / 2200)   // 1 at the deck, 0 by 2.3km
            t *= 1 - (isPrecipitating ? 0.30 : 0.20) * low * deck
        }

        // Snow is the exception to all of it. The crystals scatter forward and
        // the ground albedo throws light back up, so a snowstorm is bright even
        // when it is thick — the old table had snow at 205 against rain at 110
        // for exactly this reason.
        if precipForm == .snow || precipForm == .snowGrains || precipForm == .graupel {
            t = min(1, t * (2.4 + 1.2 * clamp01(snowDepth * 3)))
        }

        // Fog is a ceiling of zero: you are inside the cloud.
        if obscuration == .fog { t = min(t, lerp(0.06, 0.35, visibility / 1000)) }

        return max(0.012, min(1, t))
    }

    /// The same number as a 0..1 "how dark has it got", for anything that would
    /// rather add gloom than multiply light.
    var gloom: Float { clamp01(1 - pow(lightTransmission, 1.0 / 3.0)) }

    // MARK: Sight

    /// What is dimming the view, and how far you can see through it.
    ///
    /// Fog below 1000m visibility, mist 1000–5000m in air above about 80%
    /// humidity, haze the same range in drier air. The humidity test is what
    /// keeps Delhi's dry winter dust — which routinely sits at 2–3km visibility
    /// — from being drawn as a white fog when it is a brown haze.
    var obscuration: Obscuration {
        let saturated = humidity >= 85 || dewSpread <= 2.5

        /// The part that only ever looks at measured numbers: visibility in
        /// metres and how close the air is to saturation.
        func fromMeasurement() -> Obscuration {
            if visibility < 1000 {
                // Below a kilometre it is fog only if the air is wet. Otherwise
                // it is a dust event, and those look nothing alike.
                return saturated ? .fog : .haze
            }
            if visibility < 5000 { return saturated ? .mist : .haze }
            if visibility < 9000 && (aqi > 90 || smoke > 0.2 || pm10 > 60) { return .haze }
            return .none
        }

        // An observer settles it in BOTH directions. If a fresh report lists no
        // obscuration, the WMO code does not get to assert one — that negative
        // direction is the whole reason Observation.swift exists.
        if hasFreshObservation, observedFog != nil {
            if observedFog == true { return .fog }
            if observedMist == true { return .mist }
            if observedDryHaze == true { return .haze }
            return fromMeasurement()
        }
        if code == 45 || code == 48 { return .fog }
        return fromMeasurement()
    }

    /// How thick that obscuration is, 0..1.
    var obscurationDensity: Float {
        switch obscuration {
        case .none: return 0
        case .fog:  return clamp01(1 - visibility / 1200)
        case .mist: return clamp01(1 - visibility / 6000) * 0.7
        case .haze: return clamp01(1 - visibility / 12000) * 0.8
        }
    }

    /// Visibility through the precipitation itself, metres.
    ///
    /// Snow is far worse than rain at the same liquid-equivalent rate — the
    /// crystals are large, numerous and highly scattering, which is why snow's
    /// light/moderate/heavy categories are DEFINED by visibility while rain's
    /// are defined by rate. Rasmussen et al. (1999) give visibility inversely
    /// proportional to snowfall rate with a factor-of-several spread depending
    /// on crystal type and wetness.
    var precipVisibility: Float {
        guard isPrecipitating else { return visibility }
        let rate = max(0.05, precipRate)
        let byPrecip: Float
        switch precipForm {
        case .snow, .snowGrains:
            // ~1000m at 1mm/h liquid equivalent, ~250m at 4mm/h. Dendrites
            // scatter more than compact crystals.
            let habitK: Float = (snowHabit == .dendrite || snowHabit == .plate) ? 800 : 1200
            byPrecip = habitK / rate
        case .graupel, .icePellets, .hail:
            byPrecip = 4000 / rate
        case .drizzle:
            // Drizzle is optically thick for how little water it is: enormous
            // numbers of very small drops.
            byPrecip = 3000 / max(0.15, rate)
        default:
            byPrecip = 9000 / sqrt(rate)
        }
        return max(60, min(visibility, byPrecip))
    }

    // MARK: Wind, ahead of the storm

    /// The dry gust front: a thunderstorm's downdraft hits the ground and
    /// spreads out ahead of the cell, so the wind arrives BEFORE the rain does.
    /// Sharp temperature drop, sharp wind shift, and a dark shelf on the
    /// horizon, minutes ahead of the first drop.
    ///
    /// Requires measured gusts and a storm somebody has actually reported —
    /// never CAPE, and never while it is already raining here, because by then
    /// the front has passed.
    var gustFrontStrength: Float {
        guard !isPrecipitating else { return 0 }
        let stormNearby = isThundering || obs(observedVicinity) == true
            || obs(observedSquall) == true
        guard stormNearby else { return 0 }
        guard gusts >= 32 else { return 0 }
        let byGust = clamp01((gusts - 32) / 40)
        let bySpread = clamp01((gustiness - 0.3) / 0.5)
        return clamp01(byGust * 0.55 + bySpread * 0.45)
    }

    /// Blowing snow — lying snow picked back up. Needs snow on the ground and
    /// wind to lift it, both measured.
    var blowingSnow: Float {
        if let b = obs(observedBlowingSnow), b { return clamp01(0.5 + gustiness * 0.5) }
        guard snowDepth > 0.02, temperature < 0, wind >= 25 else { return 0 }
        return clamp01((wind - 25) / 35)
    }

    // MARK: Diagnostics

    /// One block, for the log and the comparison harness. Every number here is
    /// derived, so if the scene looks wrong this says which step decided it.
    var presentationSummary: String {
        var lines: [String] = []
        lines.append(String(format:
            "  phase %@  morph %@  form %@  habit %@",
            precipPhase.title, morphology.title, precipForm.title, snowHabit.title))
        lines.append(String(format:
            "  rate %.2f mm/h (window %.0fmin, shower frac %.2f)  approach %.2f  clearing %.2f",
            precipRate, precipWindow, showerFraction, approachProgress, clearingProgress))
        if nowcastSlots > 0 {
            lines.append(String(format:
                "  nowcast %d slots, %d wet, %d runs  to-precip %@  since %@  next60 %.2fmm past60 %.2fmm",
                nowcastSlots, nowcastWetSlots, nowcastRuns,
                minutesToPrecip < 0 ? "—" : String(format: "%.0fmin", minutesToPrecip),
                minutesSincePrecip < 0 ? "—" : String(format: "%.0fmin", minutesSincePrecip),
                precipNext60, precipPast60))
        } else {
            lines.append("  nowcast unavailable — phase capped at thickening")
        }
        if hasTrend {
            lines.append(String(format:
                "  trend 3h: cover %+.0f%%  low %+.0f%%  pressure %+.1fhPa  temp %+.1fC  cape %+.0f",
                coverTrend, lowTrend, pressureTrend, temperatureTrend, capeTrend))
        }
        lines.append(String(format:
            "  fall %.2f m/s  streak %.2f  flutter %.2f  patch %.2f  band %.2f",
            fallSpeed, streakLength, flutter, patchiness, bandedness))
        lines.append(String(format:
            "  light %.3f (~%.0f lux of 100k)  gloom %.2f  cbase %.0f  ceiling %@",
            lightTransmission, lightTransmission * 100_000, gloom,
            continuousCloudBase,
            ceiling < 0 ? "—" : String(format: "%.0fm", ceiling)))
        lines.append(String(format:
            "  obscuration %@ %.2f  vis %.1fkm -> through precip %.1fkm  gust front %.2f  blowing snow %.2f",
            obscuration.title, obscurationDensity, visibility / 1000,
            precipVisibility / 1000, gustFrontStrength, blowingSnow))
        return lines.joined(separator: "\n")
    }

    /// Cloud-deck base brightness, 0-255, continuous.
    ///
    /// The old hand-tuned table in `SceneKind.cbase` turned out to be very close
    /// to 255·∛T for the transmissions above — 218 sun, 170 cloud, 110 rain, 82
    /// thunder come out as T of 0.63, 0.30, 0.080 and 0.033, which is exactly the
    /// illuminance ladder. Brightness perception going as roughly the cube root
    /// of luminance is why.
    ///
    /// It used to be clamped into a ±band around that table's value for the
    /// current `effectiveKind`, "so a bad transmission can never take the sky
    /// somewhere the tuning has never been". That clamp is gone. It let a
    /// CLASSIFICATION overrule a measurement: `effectiveKind` is derived from a
    /// WMO code, and the deck brightness of a real sky is not a function of which
    /// of six buckets an integer code fell into. Two skies with identical
    /// measured transmission would render at different brightness because one was
    /// filed as `.cloud` and the other as `.rain`, and a correctly measured dark
    /// afternoon could be lifted back up simply because the code said `.cloud`.
    ///
    /// Nothing is needed in its place. `lightTransmission` is a product of
    /// per-layer transmissions, precipitation rate, measured ceiling, snow albedo
    /// and fog, and it already returns `max(0.012, min(1, t))` — so this is
    /// bounded to 58…255 by construction, without consulting a table.
    var continuousCloudBase: Float {
        255 * pow(lightTransmission, 1.0 / 3.0)
    }
}

// MARK: - Easing a reading in
//
// A fetch lands every ten minutes and used to be ADOPTED: the moment the reply
// parsed, the cover, the rain, the wind and the light all stepped to their new
// values inside one frame. Nothing about a sky does that. The user's own
// description of what is wrong with it is the specification for this type:
//
//     "in real life the clouds come, darken the sky, hide the sun, and then it
//      rains. Conditions don't snap in or out."
//
// So a reading is a TARGET, not a state, and the scene chases it. The one rule
// that makes this look right rather than merely smooth is that there is no
// single smoothing constant, because the quantities do not share a timescale:
//
//     gusts            seconds        a gust is an event, not a level
//     precipitation    1-5 minutes    a shower genuinely starts in a minute
//     visibility       ~5 minutes     fog forms and lifts fast
//     wind             ~1 minute      the mean speed behind the gusts
//     cloud            ~20 minutes    a deck builds over tens of minutes
//     temperature      ~30 minutes    air has thermal mass
//     air quality      ~30 minutes    an aerosol load is a whole air mass
//
// and that the rates are ASYMMETRIC and PHASE-AWARE. Rain ramps in faster than
// it tapers out; a deck that is arriving ahead of measured precipitation
// thickens quickly; a deck that is clearing lingers long after the last drop,
// which is the "and then it stops raining but stays grey" half of the same
// sequence. `PrecipPhase` is what supplies that — see below.

/// Chases a fetched reading instead of adopting it.
///
/// Hold one of these per renderer, hand it each fetch through `retarget`, and
/// step it once a frame with `advance(dt:)`. What comes back out is the sky to
/// draw: every measured quantity part-way from where it was to where the
/// forecast says it is going, and every CLASSIFICATION (the WMO code, the
/// observer's present-weather groups, the nowcast counters) taken from the
/// reading as-is, because a classification has no midpoint to be at.
///
/// The scene's own derivations are left to do their work on the eased numbers:
/// `effectiveKind`, `morphology`, `precipForm` and `lightTransmission` all key
/// off measurements, so easing the measurements is enough to make the kind, the
/// form and the light move continuously with them. That is the whole reason the
/// easing sits here and not in the shader.
struct WeatherEaser {

    /// Time constants, in seconds, each the time to close ~63% of the gap.
    /// Named rather than inlined so the tuning is one readable table.
    enum Tau {
        // ---- cloud. The deck is the slowest thing on screen and the one the
        // complaint is really about.
        /// Ordinary thickening and thinning.
        static let cloud: Float = 1200            // 20 min
        /// A deck arriving ahead of precipitation the nowcast has already
        /// measured. This is the "the clouds come" step, and it is quick.
        static let cloudArriving: Float = 420     // 7 min
        /// After the rain stops. The deck does not evaporate with it.
        static let cloudLingering: Float = 2700   // 45 min
        /// Burning off on a drying day — slower than it built.
        static let cloudBurningOff: Float = 1500  // 25 min

        // ---- water. Fast, and asymmetric: rain arrives quicker than it leaves.
        static let rainOnset: Float = 120
        static let rainTaper: Float = 210
        /// A shower is cellular. It is over you in under a minute.
        static let showerOnset: Float = 45
        static let showerTaper: Float = 150
        /// Drizzle fades up and down out of a low deck; nothing about it is
        /// sudden.
        static let drizzleOnset: Float = 240
        /// Snow starts and stops far more gently than rain at the same rate.
        static let snowOnset: Float = 180
        static let snowTaper: Float = 420
        /// Lying snow. Accumulation and melt are hours, not minutes.
        static let snowDepth: Float = 3600

        // ---- wind
        /// Gusts are seconds by definition.
        static let gust: Float = 8
        static let wind: Float = 45
        /// A gust front is a downdraft hitting the ground. It arrives.
        static let windSquall: Float = 15
        static let windDir: Float = 150

        // ---- air
        static let temperature: Float = 1800      // 30 min
        static let humidity: Float = 600
        static let pressure: Float = 1800
        static let visibility: Float = 300        // fog forms in minutes
        static let uv: Float = 600
        static let aerosol: Float = 1800          // an AQI is an air mass
        static let convection: Float = 900
        static let levels: Float = 1800           // freezing level, PBL top
        static let ceiling: Float = 600
        static let probability: Float = 600
    }

    /// What is being drawn. Starts on the defaults — a clear calm day — which
    /// is what the scene renders before any fetch has landed.
    private(set) var shown = WeatherState()
    /// The last reading, with its nowcast clock run forward. Public so a host
    /// can log what the sky is heading toward as well as where it has got to.
    private(set) var target = WeatherState()
    /// Whether a reading has ever landed. The FIRST one is adopted outright:
    /// at launch there is no previous sky to ease away from, and easing in from
    /// the clear-day defaults would spend twenty minutes drawing weather that
    /// is not happening.
    private(set) var hasReading = false

    /// Take a new fetch.
    mutating func retarget(_ w: WeatherState) {
        guard hasReading else {
            shown = w; target = w; hasReading = true
            return
        }
        // Precipitation is an ACCUMULATION over a window, so the same number of
        // millimetres means a different rate when the window changes — the
        // hourly feed reports an hour, the 15-minute nowcast a quarter of one.
        // Rescale what is on screen into the new reading's units first, or the
        // eased value silently jumps by 4x at the seam.
        let oldW = max(1, shown.precipWindow), newW = max(1, w.precipWindow)
        if oldW != newW {
            let f = newW / oldW
            shown.precipitation *= f
            shown.rain *= f
            shown.showers *= f
            shown.snow *= f
        }
        target = w
    }

    /// Adopt a reading with no easing at all. For the offscreen stills
    /// exporter and the settings thumbnails, which draw a settled scene rather
    /// than a moving one.
    mutating func snap(to w: WeatherState) {
        shown = w; target = w; hasReading = true
    }

    /// Step the scene toward the target and return what to draw.
    ///
    /// `dt` is scene seconds. A wake fast-forward can hand in the whole gap in
    /// one call: exponential easing composes exactly over a step of any size,
    /// so replaying an hour as a single 3600-second step lands on the same
    /// place as 3600 one-second steps would.
    mutating func advance(dt: Float) -> WeatherState {
        guard hasReading, dt > 0, dt.isFinite else { return shown }
        // Two hours of easing is fully settled for every constant in the table
        // above, so a longer step buys nothing and only risks overflow.
        let step = min(dt, 7200)

        // ---- the nowcast clock runs on its own.
        //
        // `minutesToPrecip` is a countdown measured at fetch time. Freezing it
        // between fetches makes `approachProgress` — and with it the pre-rain
        // darkening — a staircase with a ten-minute tread. Running it forward
        // is what turns the lead-in into the continuous thing the user
        // described: the sky darkens all the way in, not in two steps.
        let mins = step / 60
        if target.nowcastSlots > 0 {
            if target.minutesToPrecip >= 0 {
                target.minutesToPrecip = max(0, target.minutesToPrecip - mins)
            }
            if target.minutesSincePrecip >= 0 {
                target.minutesSincePrecip += mins
            }
        }

        // Where in the arc of the event the READING says we are. This is what
        // makes the deck lead the rain and lag it, and it is the reason
        // PrecipPhase exists — it was computed and read by nothing but the
        // diagnostics block until now.
        let phase = target.precipPhase
        let morph = target.morphology

        // Everything not listed below is a classification, an observation or a
        // counter, and is adopted whole: there is no halfway between "an
        // observer reported hail" and "they did not".
        var next = target

        // ---- cloud
        let deckTau = cloudTau(phase: phase, rising: target.cloudLow >= shown.cloudLow)
        next.cover     = Self.ease(shown.cover,     target.cover,     step, deckTau)
        next.cloudLow  = Self.ease(shown.cloudLow,  target.cloudLow,  step, deckTau)
        next.cloudMid  = Self.ease(shown.cloudMid,  target.cloudMid,  step,
                                   cloudTau(phase: phase, rising: target.cloudMid >= shown.cloudMid))
        next.cloudHigh = Self.ease(shown.cloudHigh, target.cloudHigh, step, Tau.cloud)

        // ---- water
        let liquidTau = precipTau(phase: phase, morph: morph, frozen: false,
                                  rising: target.precipAmount >= shown.precipAmount)
        let solidTau = precipTau(phase: phase, morph: morph, frozen: true,
                                 rising: target.snow >= shown.snow)
        next.precipitation = Self.ease(shown.precipitation, target.precipitation, step, liquidTau, floor: 0.045)
        next.rain          = Self.ease(shown.rain,          target.rain,          step, liquidTau, floor: 0.045)
        next.showers       = Self.ease(shown.showers,       target.showers,       step, liquidTau, floor: 0.045)
        next.snow          = Self.ease(shown.snow,          target.snow,          step, solidTau,  floor: 0.045)
        next.snowDepth     = Self.ease(shown.snowDepth,     target.snowDepth,     step, Tau.snowDepth)
        next.precipProbability = Self.ease(shown.precipProbability, target.precipProbability,
                                           step, Tau.probability)

        // ---- wind. The gust front is the one part of a storm that genuinely
        // arrives before everything else, so when the reading says one is on
        // its way the mean wind is allowed to move at nearly gust speed.
        let windTau = (phase == .imminent && target.gusts >= 32) ? Tau.windSquall : Tau.wind
        next.wind    = Self.ease(shown.wind,  target.wind,  step, windTau)
        next.gusts   = Self.ease(shown.gusts, target.gusts, step, Tau.gust)
        next.windDir = Self.easeAngle(shown.windDir, target.windDir, step, Tau.windDir)

        // ---- air
        next.temperature = Self.ease(shown.temperature, target.temperature, step, Tau.temperature)
        next.apparent    = Self.ease(shown.apparent,    target.apparent,    step, Tau.temperature)
        next.dewPoint    = Self.ease(shown.dewPoint,    target.dewPoint,    step, Tau.temperature)
        next.humidity    = Self.ease(shown.humidity,    target.humidity,    step, Tau.humidity)
        next.pressureMSL = Self.ease(shown.pressureMSL, target.pressureMSL, step, Tau.pressure)
        next.surfacePressure = Self.ease(shown.surfacePressure, target.surfacePressure, step, Tau.pressure)
        next.visibility  = Self.ease(shown.visibility,  target.visibility,  step, Tau.visibility)
        next.uv          = Self.ease(shown.uv,          target.uv,          step, Tau.uv)

        // ---- aerosol
        next.aqi   = Self.ease(shown.aqi,   target.aqi,   step, Tau.aerosol)
        next.pm25  = Self.ease(shown.pm25,  target.pm25,  step, Tau.aerosol)
        next.pm10  = Self.ease(shown.pm10,  target.pm10,  step, Tau.aerosol)
        next.smoke = Self.ease(shown.smoke, target.smoke, step, Tau.aerosol)

        // ---- convection and the levels
        next.cape        = Self.ease(shown.cape,        target.cape,        step, Tau.convection)
        next.liftedIndex = Self.ease(shown.liftedIndex, target.liftedIndex, step, Tau.convection)
        next.convectiveInhibition = Self.ease(shown.convectiveInhibition,
                                              target.convectiveInhibition, step, Tau.convection)
        next.freezingLevel = Self.ease(shown.freezingLevel, target.freezingLevel, step, Tau.levels)
        next.boundaryLayer = Self.ease(shown.boundaryLayer, target.boundaryLayer, step, Tau.levels)

        // ---- ceiling. -1 is "nobody measured one", which is not a height and
        // must never be eased through: a station appearing or disappearing
        // would otherwise sweep the cloud base up or down through the whole
        // troposphere on its way to or from the sentinel.
        next.ceiling = (shown.ceiling < 0 || target.ceiling < 0)
            ? target.ceiling
            : Self.ease(shown.ceiling, target.ceiling, step, Tau.ceiling)

        shown = next
        return shown
    }

    // ---- rate selection

    /// How fast the deck moves, given where in the event we are.
    private func cloudTau(phase: PrecipPhase, rising: Bool) -> Float {
        switch phase {
        case .imminent:   return rising ? Tau.cloudArriving : Tau.cloud
        case .thickening: return rising ? Tau.cloudArriving * 1.6 : Tau.cloud
        case .active:     return rising ? Tau.cloudArriving : Tau.cloudLingering
        case .clearing:   return rising ? Tau.cloud : Tau.cloudLingering
        case .clear:      return rising ? Tau.cloud : Tau.cloudBurningOff
        }
    }

    /// How fast precipitation comes and goes. A shower is over you in a minute
    /// and gone as quickly; frontal rain fades up and down; nothing stops dead.
    private func precipTau(phase: PrecipPhase, morph: PrecipMorphology,
                           frozen: Bool, rising: Bool) -> Float {
        if frozen { return rising ? Tau.snowOnset : Tau.snowTaper }
        switch morph {
        case .showery, .squally:
            return rising ? Tau.showerOnset : Tau.showerTaper
        case .drizzle:
            return rising ? Tau.drizzleOnset : Tau.rainTaper
        case .steady, .none:
            // Coming out of an event the deck is still there and the last of
            // the rain trails off under it, so the taper is the slower one.
            if !rising && phase == .clearing { return Tau.rainTaper * 1.25 }
            return rising ? Tau.rainOnset : Tau.rainTaper
        }
    }

    // ---- the arithmetic

    /// Fraction of the remaining gap to close in `dt` at time constant `tau`.
    @inline(__always)
    private static func alpha(_ dt: Float, _ tau: Float) -> Float {
        guard tau > 0 else { return 1 }
        return 1 - exp(-dt / tau)
    }

    /// Exponential approach, with a floor that snaps the last sliver away.
    ///
    /// The floor matters for water specifically: `isPrecipitating` is gated at
    /// 0.05mm, so an asymptote that never quite reaches zero would leave the
    /// engine believing a trace of rain was falling for ever.
    @inline(__always)
    private static func ease(_ cur: Float, _ tgt: Float, _ dt: Float, _ tau: Float,
                             floor: Float = 0) -> Float {
        guard cur.isFinite else { return tgt }
        guard tgt.isFinite else { return cur }
        if cur == tgt { return cur }
        let v = cur + (tgt - cur) * alpha(dt, tau)
        return abs(tgt - v) <= floor ? tgt : v
    }

    /// The same, the shortest way round the compass — so a wind backing from
    /// 350 to 10 degrees goes forward through north rather than sweeping the
    /// long way round through south.
    @inline(__always)
    private static func easeAngle(_ cur: Float, _ tgt: Float, _ dt: Float, _ tau: Float) -> Float {
        guard cur.isFinite, tgt.isFinite else { return tgt }
        var d = (tgt - cur).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        var v = cur + d * alpha(dt, tau)
        if v < 0 { v += 360 } else if v >= 360 { v -= 360 }
        return v
    }
}

// MARK: - Scene state

/// The full description of what to draw, assembled on the CPU each frame.
struct SceneState {
    var astro = AstroState()
    var weather = WeatherState()

    /// Which compass direction the display faces; the sky maps az relative to
    /// this, so the sun rises on the correct side of the screen.
    var facingAz: Float = 180

    var headingMode: HeadingMode = .custom

    /// Where the view should be looking right now. In moving mode this is the
    /// azimuth of whatever body is up — sun while it is above civil twilight,
    /// otherwise the moon if it has risen. Below both, it keeps tracking the
    /// sun so dawn arrives already centred rather than swinging into place.
    var headingTarget: Float {
        guard headingMode == .dynamic else { return facingAz }
        if astro.sunAlt > -6 { return astro.sunAz }
        if astro.moonAlt > 0 { return astro.moonAz }
        return astro.sunAz
    }

    var shape: MosaicShape = .square
    var finish: MosaicFinish = .glass

    /// Nominal cell rows down the screen. Cell size derives from this, so the
    /// mosaic keeps the same visual scale on any display.
    var gridRows: Int = 36

    /// Mosaic colour quantisation step; higher is chunkier.
    var poster: Float = 16

    // ---- Relief. The mosaic is a wall of extruded blocks; these are its
    // material and its light. See the RELIEF section of Scene.metal.

    /// How far the blocks stand out of the wall, 0 flat to 1 deep.
    var reliefDepth: Float = 0.5
    /// How much block height follows FEATURES rather than plain tone: 0 is the
    /// old straight luminance mapping, 1 presses the smooth sky flat and lets
    /// the moon, the sun and lightning stand right out of the wall.
    ///
    /// There is no light-angle setting. The light is the sun and the moon, at
    /// the screen positions they are actually drawn at; see PASS B.
    var reliefEmphasis: Float = 0.8
    /// How hard that light is, 0..1.
    var lightIntensity: Float = 0.8
    /// How far the view is displaced through the block. Glass only.
    var refraction: Float = 0.3
    /// Per-channel split of that displacement — the chromatic fringe. Glass only.
    var dispersion: Float = 0.15
    /// Scatter of the transmitted image. Glass only.
    var frost: Float = 0
    /// Per-block jitter of height, tilt and rotation, so the courses are not
    /// perfectly regular.
    var splay: Float = 0.15

    /// How long a block takes to RISE to a new height, 0..1, where 0 is the old
    /// behaviour — the height field is assigned, so a block that should be
    /// taller simply is taller in the next frame.
    ///
    /// The height itself is still produced by `heightPass` from a cell's
    /// prominence; this only decides how fast the displayed height chases the
    /// one the shader just computed. See `ElementalRenderer.riseAlpha`, which
    /// is where a wall of blocks becomes a wall of blocks that MOVES.
    var reliefRise: Float = 0.4

    /// Skip the detail passes (moon terminator, sharp stars).
    var lowFX: Bool = false

    // ---- derived, matching the top of drawScene

    var covF: Float { max(0, min(1, weather.cover / 100)) }
    var aqiF: Float { max(0, min(1, max(0, weather.aqi - 30) / 320)) }
    var smokeF: Float { max(0, min(1, weather.smoke)) }

    /// roomstand.py:2237
    var skyBrAmt: Float { SceneState.skyBr(astro.sunAlt) }

    /// roomstand.py:2269
    var posterQ: Float { max(3, (poster * (0.3 + 0.7 * skyBrAmt)).rounded()) }

    /// Night floor boost — raises dark cells so the grid stays visible against
    /// the sky background; moonlight lifts it further (roomstand.py:2385).
    var nightBoost: Float {
        // Moonlight does lift the whole sky, but nothing like this much. At
        // 0.17 per illuminated percent a bright moon added twenty luminance to
        // every cell in the frame — a flat, global lift that is most of why a
        // clear night rendered as pale periwinkle instead of dark.
        //
        // It also has to fall off with the moon's altitude. A moon near the
        // horizon lights the sky far less than one overhead, because its light
        // is crossing the whole depth of the atmosphere to get here; treating a
        // rising moon and a high one as equal is not a small error.
        let alt = max(0, min(1, astro.moonAlt / 45))
        let moonLift = astro.moonAlt > 0
            ? astro.moonIllum * 0.055 * (0.35 + 0.65 * alt) : 0
        return (max(0, 0.92 - skyBrAmt) * (6 + moonLift)).rounded()
    }

    /// Cloud base brightness, scaled continuously by sky brightness.
    ///
    /// The per-condition constant became a continuous function of how much light
    /// actually gets through the deck — see `WeatherState.continuousCloudBase`.
    /// It still lands on the old table's values at the old table's conditions,
    /// and is clamped so it can never leave the band the scene was tuned in;
    /// what it adds is the middle, which is where most weather lives, and the
    /// LEAD — the deck darkening before the first drop rather than at it.
    var cbase: Float { weather.continuousCloudBase * skyBrAmt }

    static func skyBr(_ sAlt: Float) -> Float {
        func skl(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * max(0, min(1, t)) }
        if sAlt <= -18 { return 0.04 }
        if sAlt <=  -6 { return skl(0.04, 0.18, (sAlt + 18) / 12) }
        if sAlt <=   0 { return skl(0.18, 0.46, (sAlt + 6) / 6) }
        if sAlt <=   6 { return skl(0.46, 0.82, sAlt / 6) }
        if sAlt <=  22 { return skl(0.82, 1.00, (sAlt - 6) / 16) }
        return 1
    }
}
