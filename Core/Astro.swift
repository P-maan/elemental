//  Astro.swift — sun, moon and star positions.
//
//  Straight port of sunPos / moonPos / moonPhase / updateAstro and the bright
//  star catalog from roomstand.py:1585-1698. Runs on the CPU roughly once a
//  minute; the result is ~40 floats plus a small star buffer, so it costs
//  nothing next to the per-frame work.

import Foundation

private let D2R = Double.pi / 180
private let R2D = 180 / Double.pi

struct AstroState {
    var sunAlt: Float = 0, sunAz: Float = 0
    var moonAlt: Float = 0, moonAz: Float = 0
    var moonIllum: Float = 0       // percent
    var moonPhaseN: Float = 0      // 0..1 through the synodic month
    var moonAge: Float = 0         // days
    var stars: [GPUStar] = []

    /// How deep in the earth's shadow the moon is right now, 0..1.
    ///
    /// 0 is no eclipse. Around 0.3 the limb is visibly bitten; at 1 the moon is
    /// wholly inside the umbra and turns the deep copper red that the atmosphere
    /// refracts round the earth into the shadow — the thing everybody calls a
    /// blood moon. There is nothing to fetch for this: it is pure geometry, so
    /// the scene can show it at the right minute of the right night whether or
    /// not the machine has ever been online.
    var lunarEclipse: Float = 0
}

struct Coordinate: Codable, Equatable {
    var latitude: Double
    var longitude: Double
}

enum Astro {

    // MARK: - Rare events, from geometry alone

    /// How deep the moon is in the earth's umbra, 0..1.
    ///
    /// A lunar eclipse needs two things at once and both are cheap to test.
    ///
    ///   1. FULL MOON. The moon must be opposite the sun, because the shadow it
    ///      is falling into is the earth's and the earth is between them.
    ///   2. NEAR A NODE. The moon's orbit is tilted about 5.14 degrees to the
    ///      ecliptic, which is why there is not an eclipse every month — most
    ///      full moons pass above or below the shadow entirely. Only when the
    ///      moon is also crossing the ecliptic plane does it go through.
    ///
    /// The umbra at the moon's distance is roughly 1.4 degrees in radius against
    /// the moon's own 0.26, so the geometry is forgiving: an ecliptic latitude
    /// under about a degree gives a total eclipse, and under about 1.6 a partial
    /// one. That tolerance is what makes a low-precision series good enough here
    /// — we need to know that tonight is the night and how deep it goes, not to
    /// predict contact times to the second.
    static func lunarEclipseDepth(date: Date, moonAlt: Double) -> Double {
        // Below the horizon it is not our eclipse to draw. Somebody on the other
        // side of the planet is watching it; here the moon is simply not up.
        guard moonAlt > -2 else { return 0 }

        let d = julianDay(date) - 2451545.0
        // Mean elongation of the moon from the sun. 180 degrees is full.
        let D = (297.8501921 + 12.19074911 * d).truncatingRemainder(dividingBy: 360)
        // Argument of latitude: how far the moon is from its ascending node.
        // Zero or 180 means it is crossing the ecliptic — where the shadow is.
        let F = (93.2720950 + 13.22935024 * d).truncatingRemainder(dividingBy: 360)

        // Distance from exact full, in degrees.
        var fromFull = abs(((D - 180).truncatingRemainder(dividingBy: 360) + 540)
            .truncatingRemainder(dividingBy: 360) - 180)
        fromFull = min(fromFull, 360 - fromFull)
        // The moon moves ~12.19 degrees of elongation a day, and the whole of a
        // total eclipse fits inside a few hours, so anything beyond a couple of
        // degrees from full is not one.
        guard fromFull < 2.4 else { return 0 }

        // Ecliptic latitude, magnitude only.
        let fRad = F * .pi / 180
        let beta = abs(5.1454 * sin(fRad))
        guard beta < 1.7 else { return 0 }

        // Depth from both: full in elongation AND close to the node.
        let byNode = max(0, min(1, (1.7 - beta) / 1.1))
        let byPhase = max(0, min(1, (2.4 - fromFull) / 1.6))
        return byNode * byPhase
    }

    // MARK: - Julian day

    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400 + 2440587.5
    }

    /// Fraction through the synodic month, 0 = new moon (roomstand.py:1585).
    /// Reference epoch is the new moon of 2000-01-06 18:14 UTC.
    static func moonPhase(_ date: Date) -> Double {
        let synodic = 29.530588853
        let ref = 947_182_440.0 / 86400            // 2000-01-06T18:14:00Z
        let days = date.timeIntervalSince1970 / 86400 - ref
        let m = days.truncatingRemainder(dividingBy: synodic)
        return ((m + synodic).truncatingRemainder(dividingBy: synodic)) / synodic
    }

    // MARK: - Sun

    static func sunPosition(lat: Double, lon: Double, date: Date) -> (alt: Double, az: Double) {
        let n = julianDay(date) - 2451545.0
        let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360)
        let lam = L + 1.915 * sin(g * D2R) + 0.020 * sin(2 * g * D2R)
        let eps = 23.439 - 0.0000004 * n
        let sinL = sin(lam * D2R), cosL = cos(lam * D2R)
        let ra = atan2(sinL * cos(eps * D2R), cosL) * R2D
        let dec = asin(sinL * sin(eps * D2R)) * R2D
        let gmst = (280.46061837 + 360.98564736629 * n).truncatingRemainder(dividingBy: 360)
        return horizontal(gmst: gmst, lon: lon, ra: ra, dec: dec, lat: lat)
    }

    // MARK: - Moon

    static func moonPosition(lat: Double, lon: Double, date: Date)
        -> (alt: Double, az: Double, illum: Double, age: Double)
    {
        let jd = julianDay(date)
        let T = (jd - 2451545.0) / 36525
        let Lm = (218.3164477 + 481267.88123421 * T).truncatingRemainder(dividingBy: 360)
        let M  = (357.5291092 +  35999.0502909 * T).truncatingRemainder(dividingBy: 360)
        let Mm = (134.9633964 + 477198.8675055 * T).truncatingRemainder(dividingBy: 360)
        let D  = (297.8501921 + 445267.1114034 * T).truncatingRemainder(dividingBy: 360)
        let F  = ( 93.2720950 + 483202.0175233 * T).truncatingRemainder(dividingBy: 360)

        let lam = Lm + 6.289 * sin(Mm * D2R) - 1.274 * sin((2 * D - Mm) * D2R)
                     + 0.658 * sin(2 * D * D2R) - 0.186 * sin(M * D2R)
        let bet = 5.128 * sin(F * D2R) + 0.281 * sin((Mm + F) * D2R)
                - 0.280 * sin((Mm - F) * D2R) - 0.173 * sin((2 * D - F) * D2R)
        let eps = 23.439 - 0.013 * T

        let ra = atan2(sin(lam * D2R) * cos(eps * D2R) - tan(bet * D2R) * sin(eps * D2R),
                       cos(lam * D2R)) * R2D
        let dec = asin(sin(bet * D2R) * cos(eps * D2R)
                     + cos(bet * D2R) * sin(eps * D2R) * sin(lam * D2R)) * R2D

        let n = jd - 2451545.0
        let gmst = (280.46061837 + 360.98564736629 * n).truncatingRemainder(dividingBy: 360)
        let h = horizontal(gmst: gmst, lon: lon, ra: ra, dec: dec, lat: lat)

        let synodic = 29.530588853
        let phase = moonPhase(date)
        let age = phase * synodic
        let illum = (1 - cos(phase * 2 * Double.pi)) / 2 * 100
        return (h.alt, h.az, illum, age)
    }

    /// Equatorial -> horizontal for an observer, shared by sun, moon and stars.
    ///
    /// Azimuth is a true compass bearing: 0 = north, 90 = east, 180 = south.
    /// Note this differs from the reference by 180 degrees — roomstand.py's
    /// sunPos/moonPos return azimuth measured from *south* while its FACING_AZ
    /// is documented as a compass bearing. The two cancel out there because
    /// only their difference is ever used, but it makes the Pi's "FACING E"
    /// toast read 180 degrees wrong. Storing real bearings here means a facing
    /// of 180 genuinely points south.
    private static func horizontal(gmst: Double, lon: Double, ra: Double, dec: Double, lat: Double)
        -> (alt: Double, az: Double)
    {
        let ha = ((gmst + lon - ra).truncatingRemainder(dividingBy: 360) + 360)
                    .truncatingRemainder(dividingBy: 360)
        let haR = ha * D2R, latR = lat * D2R, decR = dec * D2R
        let alt = asin(sin(latR) * sin(decR) + cos(latR) * cos(decR) * cos(haR)) * R2D
        let az = (atan2(sin(haR), cos(haR) * sin(latR) - tan(decR) * cos(latR)) * R2D + 180 + 360)
                    .truncatingRemainder(dividingBy: 360)
        return (alt, az)
    }

    // MARK: - Star catalog
    //
    // Compact bright star catalog: (RA hours, Dec degrees, visual magnitude).
    // roomstand.py:1638.

    static let stars: [(ra: Double, dec: Double, mag: Double)] = [
        (6.752,-16.716,-1.46),(6.399,-52.695,-0.72),(14.660,-60.835,-0.27),
        (14.261, 19.182,-0.04),(18.616, 38.782, 0.03),(5.278, 45.998, 0.08),
        (5.242, -8.202, 0.12),(7.655,  5.225, 0.34),(1.629,-57.237, 0.46),
        (5.919,  7.407, 0.50),(14.064,-60.373, 0.61),(19.846,  8.868, 0.77),
        (12.443,-63.099, 0.77),(4.599, 16.509, 0.85),(16.490,-26.432, 0.96),
        (13.420,-11.161, 0.97),(7.755, 28.026, 1.14),(22.961,-29.622, 1.16),
        (20.690, 45.280, 1.25),(12.796,-59.689, 1.25),(10.139, 11.967, 1.35),
        (6.977,-28.972, 1.50),(7.577, 31.889, 1.57),(12.519,-57.113, 1.59),
        (17.560,-37.103, 1.62),(5.419,  6.350, 1.64),(5.438, 28.608, 1.65),
        (9.220,-69.717, 1.67),(5.603, -1.202, 1.69),(22.137,-46.961, 1.73),
        (5.679, -1.943, 1.74),(3.406, 49.861, 1.79),(11.062, 61.751, 1.79),
        (7.140,-26.393, 1.82),(17.622,-42.998, 1.86),(18.403,-34.385, 1.85),
        (8.375,-59.510, 1.86),(13.793, 49.314, 1.86),(2.530, 89.264, 2.02),
        (14.111,-36.370, 2.06),(7.401,-29.303, 2.00),(8.745,  6.420, 2.23),
        (21.526,  5.571, 2.44),(20.370, 40.257, 2.23),(15.035, 40.391, 2.37),
        (9.461, -8.658, 2.45),(16.051,-19.461, 2.30),(10.332,-70.037, 2.25),
        (7.046,-15.633, 2.43),(6.833,-32.508, 2.45),(10.897, 41.500, 2.34),
        (7.576,-14.826, 2.37),(21.310,-16.834, 2.39),(1.161, 35.621, 2.01),
        (5.994, 37.213, 2.16),(23.054, 28.082, 2.49),(2.097, 42.330, 2.26),
        (0.140, 29.091, 2.06),(17.943, 51.489, 2.24),(22.690,-46.885, 2.17),
        (4.299, -3.352, 3.00),(6.063,  5.607, 2.96),(8.044,-40.003, 1.95),
        (3.791, 24.106, 2.87),(16.836,-34.293, 2.29),(7.287,-26.777, 2.46),
        (1.911, 35.621, 2.06),(17.530,-37.295, 2.39),(15.578,-26.115, 2.56),
        (6.251, 22.513, 2.53),(4.731, -8.202, 2.77),(21.463,  5.571, 2.39),
        (6.381,-17.956, 2.00),(7.139,-26.393, 2.43),(9.134, 26.005, 2.87),
    ]

    // MARK: - Full update

    /// Recompute everything for a location and instant. Cheap enough to call
    /// once a minute; nothing here is per-frame work.
    static func update(lat: Double, lon: Double, facingAz: Double = 0, date: Date = Date()) -> AstroState {
        var s = AstroState()
        let sun = sunPosition(lat: lat, lon: lon, date: date)
        let moon = moonPosition(lat: lat, lon: lon, date: date)
        s.sunAlt = Float(sun.alt);  s.sunAz = Float(sun.az)
        s.moonAlt = Float(moon.alt); s.moonAz = Float(moon.az)
        s.moonIllum = Float(moon.illum)
        s.moonAge = Float(moon.age)
        s.moonPhaseN = Float(moonPhase(date))
        s.lunarEclipse = Float(lunarEclipseDepth(date: date, moonAlt: moon.alt))

        // Project the catalog to screen-normalised positions.
        let n = julianDay(date) - 2451545.0
        let gmst = (280.46061837 + 360.98564736629 * n).truncatingRemainder(dividingBy: 360)
        // Note we keep every star above the horizon regardless of heading, and
        // no longer fold the heading in here. With a moving heading the view can
        // swing at any moment, and reprojecting the catalog on the CPU each time
        // would be both wasteful and a frame behind — the shader does it.
        var out: [GPUStar] = []
        out.reserveCapacity(stars.count)
        for st in stars {
            let h = horizontal(gmst: gmst, lon: lon, ra: st.ra * 15, dec: st.dec, lat: lat)
            if h.alt < 2 { continue }                       // below the horizon
            let br = max(0, min(1, (3.2 - st.mag) / 4.7))   // mag -1.5..3 -> 1..0
            out.append(GPUStar(alt: Float(h.alt), az: Float(h.az), br: Float(br), _p: 0))
        }
        s.stars = out
        return s
    }
}
