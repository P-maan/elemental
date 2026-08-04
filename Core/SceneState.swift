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
// 4-byte scalar and the tail is padded to 176 bytes, so there are no vector
// alignment rules to reason about on either side. If you add a field, add it
// in both places and keep the total a multiple of 16.

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
    var glassAmp: Float = 0
    var fogOn: Float = 0
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

/// Mirrors `scKind` in roomstand.py. Cloud/rain behaviour keys off this.
enum SceneKind: Int32, Codable {
    case sun = 0, partly = 1, cloud = 2, rain = 3, snow = 4, thunder = 5

    /// roomstand.py:2387 — the cloud-deck base brightness per condition.
    var cbase: Float {
        switch self {
        case .thunder: return 82
        case .rain:    return 110
        case .snow:    return 205
        case .cloud:   return 170
        case .sun, .partly: return 218
        }
    }

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
struct WeatherState {

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
    var precipAmount: Float { max(precipitation, effectiveRain + snow * 10) }

    /// Is anything actually falling? A hair above zero, because the feeds
    /// report 0.01mm noise on dry days.
    var isPrecipitating: Bool { precipAmount >= 0.05 }

    /// Fog is observed far more reliably than it is modelled — visibility in a
    /// model is a grid-box average, and fog is famously not.
    var isFoggy: Bool {
        if hasFreshObservation, let f = observedFog { return f }
        return code == 45 || code == 48
    }

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

    /// How pronounced the glass relief is, 0 flat to 1 pressed-glass-block.
    var glassAmplify: Float = 0.3

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
    var cbase: Float { weather.effectiveKind.cbase * skyBrAmt }

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
