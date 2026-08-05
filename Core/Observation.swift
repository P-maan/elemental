//  Observation.swift — what is actually happening, as opposed to what was forecast.
//
//  Everything else in the engine comes from Open-Meteo, which is a numerical
//  weather model. A model is a prediction, and a prediction of "convective
//  available potential energy 2800 J/kg" is not the same claim as "it is
//  raining". Reading a wall of monsoon CAPE and drawing lightning all afternoon
//  over a sky that was merely overcast is exactly the failure that produces —
//  the model was not wrong about the atmosphere, we were wrong to treat its
//  potential as an event.
//
//  METAR is the other kind of source. It is an aerodrome observation, issued
//  every half hour, of what an instrument (and often a human) at a known point
//  can see right now: how much sky is covered and at what height, how far you
//  can see, and which of a fixed vocabulary of present-weather phenomena is
//  occurring. There is no forecast in it. If a METAR says no precipitation,
//  nothing is falling on that airfield, and no amount of modelled instability
//  argues otherwise.
//
//  So this is the reference the rest of the engine gets checked against, and
//  where it is fresh and close enough, corrected by. It covers only what an
//  observer can see — cloud, visibility, present weather, wind, temperature —
//  and says nothing about UV, CAPE or precipitation rate in millimetres, which
//  stay the model's job.
//
//    aviationweather.gov/api/data/metar    free, no key, JSON or raw
//
//  Fails soft in every direction: no station, no network, a stale report, or a
//  station too far away all leave the model's own reading untouched.

import Foundation

/// A decoded aerodrome observation.
struct Observation {
    var stationId = ""
    var stationName = ""
    /// Great-circle distance from the scene's location, km.
    var distanceKm: Double = 0
    /// How long ago the observation was taken.
    var age: TimeInterval = 0

    /// Sky cover by ICAO altitude band, per cent.
    var coverLow: Float = 0        // below 6,500 ft
    var coverMid: Float = 0        // 6,500 – 20,000 ft
    var coverHigh: Float = 0       // above 20,000 ft
    var coverTotal: Float = 0

    /// Height of the lowest BROKEN or OVERCAST layer, metres AGL. -1 when the
    /// sky is clear or only scattered — there is no ceiling then, which is a
    /// different fact from a high one.
    ///
    /// This is the single most useful number in a METAR that the engine was
    /// throwing away. A ceiling is a measurement of where the cloud actually is,
    /// and cloud base height is most of what decides whether an overcast reads
    /// as a high grey lid or a low oppressive one.
    var ceiling: Float = -1
    /// Base of the lowest layer of any amount, metres AGL. -1 when clear.
    var lowestBase: Float = -1

    var visibility: Float = 12000  // metres
    var temperature: Float = 20
    var dewPoint: Float = 10
    var wind: Float = 0            // km/h
    var gusts: Float = 0
    var windDir: Float = 180

    // Present weather. These are observed, not inferred.
    var raining = false
    var snowing = false
    var thundering = false
    /// FG only. Mist is a separate, much milder thing and gets its own flag.
    var fog = false
    var haze = false
    /// -1 light, 0 moderate, +1 heavy. Only meaningful while precipitating.
    var intensity: Int = 0

    // The rest of the present-weather vocabulary. METAR already distinguishes
    // convective from stratiform precipitation — SHRA is a rain SHOWER, RA is
    // continuous rain — and already distinguishes water droplets from dry
    // aerosol. Decoding only "is it raining" threw away a free, measured
    // classification of exactly the thing the scene needs to draw.
    var showery = false        // SH descriptor: convective, cellular
    var continuousPrecip = false // RA/SN/DZ with no SH descriptor
    var drizzle = false        // DZ
    var freezing = false       // FZ descriptor
    var hail = false           // GR hail, GS small hail / snow pellets
    var icePellets = false     // PL
    var blowingSnow = false    // BLSN / DRSN
    var squall = false         // SQ
    var mist = false           // BR — 1–5km in saturated air
    var dust = false           // DU / SA / PO / SS / DS
    var smoke = false          // FU
    /// VC — visible from the field, not occurring at it. A shower you can see
    /// across the valley is not a shower on your window.
    var vicinity = false

    var raw = ""

    /// Whether this is worth believing over the model.
    ///
    /// Half an hour is the standard METAR cycle, so anything under about 80
    /// minutes is either current or one missed cycle old. Distance matters more
    /// than it looks: convective rain is patchy, and a thunderstorm sitting on
    /// an airport 90km away says nothing about here. Cloud decks are broader
    /// than showers, which is why the two get different reaches below.
    var isFresh: Bool { age < 80 * 60 }

    var humidity: Float {
        // Magnus, inverted. The report gives temperature and dew point; every
        // other part of the engine wants relative humidity.
        let a = 17.27, b = 237.3
        let t = Double(temperature), td = Double(dewPoint)
        let g = (a * td) / (b + td) - (a * t) / (b + t)
        return Float(max(1, min(100, 100 * exp(g))))
    }

    /// One line, for the comparison harness and the log.
    var summary: String {
        var wx: [String] = []
        if thundering { wx.append("thunder") }
        if squall     { wx.append("squall") }
        if raining {
            let str = intensity > 0 ? "heavy" : intensity < 0 ? "light" : "moderate"
            let what = drizzle ? "drizzle" : hail ? "hail" : icePellets ? "ice pellets"
                     : freezing ? "freezing rain" : "rain"
            wx.append("\(str) \(showery ? "shower of " : "")\(what)")
        }
        if snowing    { wx.append(showery ? "snow shower" : "snow") }
        if blowingSnow { wx.append("blowing snow") }
        if fog        { wx.append("fog") }
        if mist       { wx.append("mist") }
        if smoke      { wx.append("smoke") }
        if dust       { wx.append("dust") }
        else if haze  { wx.append("haze") }
        if vicinity   { wx.append("(in vicinity)") }
        if wx.isEmpty { wx.append("no precip") }
        return String(format: "%@ %.0fkm %.0fmin ago | cloud %.0f%% (lo %.0f mid %.0f hi %.0f) ceil %@ | vis %.1fkm | %@",
                      stationId, distanceKm, age / 60,
                      coverTotal, coverLow, coverMid, coverHigh,
                      ceiling < 0 ? "none" : String(format: "%.0fm", ceiling),
                      visibility / 1000, wx.joined(separator: ", "))
    }
}

enum ObservationService {

    /// Nearest usable report to a coordinate, or nil.
    ///
    /// Searched by bounding box rather than by station id, because the caller
    /// only knows where it is, not which airfield is nearby — and a hard-coded
    /// station list would work for two cities and fail for every other.
    static func fetch(lat: Double, lon: Double) async -> Observation? {
        // Roughly 165km of latitude; longitude widened by the cosine so the box
        // stays about square in kilometres at any latitude. Far enough to find a
        // station almost anywhere populated, and the distance test below decides
        // what is actually close enough to believe.
        let dLat = 1.5
        let dLon = 1.5 / max(0.25, cos(lat * .pi / 180))
        var c = URLComponents(string: "https://aviationweather.gov/api/data/metar")!
        c.queryItems = [
            .init(name: "bbox", value: String(format: "%.3f,%.3f,%.3f,%.3f",
                                              lat - dLat, lon - dLon, lat + dLat, lon + dLon)),
            .init(name: "format", value: "json"),
        ]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        var best: Observation?
        for row in rows {
            guard var o = decode(row) else { continue }
            o.distanceKm = haversine(lat, lon, (row["lat"] as? NSNumber)?.doubleValue ?? lat,
                                               (row["lon"] as? NSNumber)?.doubleValue ?? lon)
            guard o.isFresh else { continue }
            if best == nil || o.distanceKm < best!.distanceKm { best = o }
        }
        return best
    }

    private static func decode(_ row: [String: Any]) -> Observation? {
        guard let id = row["icaoId"] as? String else { return nil }
        var o = Observation()
        o.stationId = id
        o.stationName = (row["name"] as? String) ?? id
        o.raw = (row["rawOb"] as? String) ?? ""

        if let t = (row["obsTime"] as? NSNumber)?.doubleValue {
            o.age = max(0, Date().timeIntervalSince1970 - t)
        } else {
            return nil          // undatable is unusable — it might be days old
        }

        func f(_ k: String, _ fallback: Float) -> Float {
            (row[k] as? NSNumber)?.floatValue ?? fallback
        }
        o.temperature = f("temp", 20)
        o.dewPoint    = f("dewp", 10)
        o.windDir     = f("wdir", 180)
        o.wind        = f("wspd", 0) * 1.852        // knots -> km/h
        o.gusts       = max(o.wind, f("wgst", 0) * 1.852)
        // Statute miles in the feed. "10+" comes through as 10 and means
        // unlimited, which is the same thing for anything we draw.
        o.visibility  = f("visib", 6.2) * 1609.34

        decodeClouds(row["clouds"] as? [[String: Any]] ?? [], into: &o)
        decodePresentWeather((row["wxString"] as? String) ?? "", into: &o)
        return o
    }

    /// Sky cover, by band.
    ///
    /// METAR layers are CUMULATIVE — BKN035 means the sky is broken at and
    /// below 3,500ft, not that this one layer is broken — so the reported value
    /// of a higher layer already contains everything under it. Subtracting what
    /// the bands below already account for recovers roughly what each band
    /// contributes on its own, which is what the renderer wants: it draws the
    /// three decks separately and a cirrus sky must not grow a low lid.
    private static func decodeClouds(_ layers: [[String: Any]], into o: inout Observation) {
        func pct(_ cover: String) -> Float {
            switch cover {
            case "SKC", "CLR", "NSC", "NCD", "CAVOK": return 0
            case "FEW": return 19            //  1–2 oktas
            case "SCT": return 44            //  3–4
            case "BKN": return 75            //  5–7
            case "OVC": return 100           //  8
            case "OVX", "VV":  return 100    //  sky obscured: totally hidden
            default:    return 0
            }
        }
        var lo: Float = 0, mid: Float = 0, hi: Float = 0
        var ceilingFt = Float.greatestFiniteMagnitude
        var lowestFt = Float.greatestFiniteMagnitude
        for l in layers {
            let cover = (l["cover"] as? String) ?? ""
            let p = pct(cover)
            guard p > 0 else { continue }
            // A vertical-visibility report has no base; treat it as ground level.
            let base = (l["base"] as? NSNumber)?.floatValue ?? 0
            lowestFt = min(lowestFt, base)
            // "Ceiling" in aviation means the lowest layer of BKN or more —
            // the height at which the sky is effectively closed over you.
            if p >= 75 { ceilingFt = min(ceilingFt, base) }
            if base < 6500        { lo  = max(lo,  p) }
            else if base < 20000  { mid = max(mid, p) }
            else                  { hi  = max(hi,  p) }
        }
        o.ceiling = ceilingFt < .greatestFiniteMagnitude ? ceilingFt * 0.3048 : -1
        o.lowestBase = lowestFt < .greatestFiniteMagnitude ? lowestFt * 0.3048 : -1
        o.coverTotal = max(lo, max(mid, hi))
        o.coverLow   = lo
        o.coverMid   = max(0, mid - lo)
        o.coverHigh  = max(0, hi - max(lo, mid))
    }

    /// Present weather, from the METAR vocabulary.
    ///
    /// Descriptors and intensity prefixes are stripped off and the phenomenon
    /// codes matched: TS thunderstorm, RA rain, DZ drizzle, SN snow, GR/GS hail,
    /// FG fog, BR mist, HZ haze, FU smoke, DU/SA dust and sand. "VC" means "in
    /// the vicinity" — visible from the field but not at it, so it is read as
    /// weather nearby rather than weather here.
    /// A METAR group is `[intensity][descriptor][phenomenon]`, and the
    /// DESCRIPTOR is the part that was being thrown away. `SH` means shower —
    /// convective, cellular, brief. `FZ` means the drops are supercooled and
    /// will glaze whatever they land on. `BL` and `DR` mean the snow is not
    /// falling, it is being picked back up off the ground. `TS` means an
    /// observer heard thunder. Those are measurements of morphology, made by a
    /// person or an instrument at a known point, and they are worth more than
    /// anything this program can derive from a grid-box average.
    private static func decodePresentWeather(_ s: String, into o: inout Observation) {
        guard !s.isEmpty else { return }
        let up = s.uppercased()
        for token in up.split(separator: " ") {
            var t = String(token)
            // Vicinity: something is going on, but not over the station. Keep
            // the haze/fog reading but do not claim it is raining here.
            let vicinity = t.hasPrefix("VC")
            if vicinity { t.removeFirst(2); o.vicinity = true }
            if t.hasPrefix("-") { o.intensity = -1; t.removeFirst() }
            else if t.hasPrefix("+") { o.intensity = 1; t.removeFirst() }

            // ---- descriptors
            let shower = t.contains("SH")
            let freezing = t.contains("FZ")
            let blowing = t.contains("BL") || t.contains("DR")

            // ---- phenomena
            let rainLike = t.contains("RA")
            let drizzleLike = t.contains("DZ")
            let snowLike = t.contains("SN") || t.contains("SG") || t.contains("IC")
            let hailLike = t.contains("GR") || t.contains("GS")
            let pelletLike = t.contains("PL")

            if t.contains("TS") { o.thundering = !vicinity }
            if t.contains("SQ") { o.squall = !vicinity }
            if !vicinity {
                if rainLike || drizzleLike { o.raining = true }
                if snowLike { o.snowing = blowing ? o.snowing : true }
                if hailLike || pelletLike { o.raining = true }
                if t.contains("UP") { o.raining = true }     // unidentified precipitation

                if drizzleLike { o.drizzle = true }
                if hailLike { o.hail = true }
                if pelletLike { o.icePellets = true }
                if freezing && (rainLike || drizzleLike) { o.freezing = true }
                if blowing && snowLike { o.blowingSnow = true }

                // Shower against continuous. Only meaningful for something that
                // is actually falling, and blowing snow is neither.
                let falling = rainLike || drizzleLike || snowLike || hailLike || pelletLike
                if falling && !blowing {
                    if shower { o.showery = true } else { o.continuousPrecip = true }
                }
            }
            // VCSH / VCTS deliberately set nothing beyond `vicinity`: convection
            // in sight is worth knowing about for the gust front and is worth
            // nothing at all as a claim about this window.

            // ---- obscurations. Water droplets and dry aerosol are different
            // substances and are kept apart.
            if t.contains("FG") { o.fog = true }
            if t.contains("BR") { o.mist = true }
            if t.contains("FU") { o.smoke = true; o.haze = true }
            if t.contains("DU") || t.contains("SA") || t.contains("PO")
                || t.contains("SS") || t.contains("DS") { o.dust = true; o.haze = true }
            if t.contains("HZ") || t.contains("PY") { o.haze = true }
        }
    }

    private static func haversine(_ lat1: Double, _ lon1: Double,
                                  _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - Reconciling the two

extension WeatherState {

    /// How far an observation is allowed to speak for, by phenomenon.
    ///
    /// These differ because the phenomena differ in scale. A cloud deck is a
    /// synoptic feature tens of kilometres across, so a station at 70km is
    /// usually under the same sky. A thunderstorm cell is a few kilometres
    /// wide; one sitting over an airport 60km away tells you nothing about
    /// here, and believing it is how you end up drawing lightning on a calm
    /// evening. Precipitation sits in between — frontal rain is broad, monsoon
    /// showers are not.
    private static let cloudReachKm = 85.0
    private static let precipReachKm = 45.0
    private static let stormReachKm = 25.0

    /// Correct the model against what is being observed.
    ///
    /// Only the fields an observer can actually see are touched. CAPE, UV,
    /// precipitation in millimetres per hour and everything else the report
    /// does not contain are left exactly as the model gave them.
    ///
    /// The important direction is negative. The model saying "rain" and the
    /// station saying "no present weather" means it is not raining, and that is
    /// the case that was making the wallpaper wrong — a forecast hour of rain
    /// drawn over a dry afternoon. The positive direction is weaker: a station
    /// can be under a shower that has not reached here.
    mutating func reconcile(with o: Observation) {
        guard o.isFresh else { return }

        if o.distanceKm <= Self.cloudReachKm {
            cover     = o.coverTotal
            cloudLow  = o.coverLow
            cloudMid  = o.coverMid
            cloudHigh = o.coverHigh
            visibility = o.visibility
            humidity   = o.humidity
            temperature = o.temperature
            dewPoint    = o.dewPoint
            wind        = o.wind
            gusts       = max(gusts, o.gusts)
            windDir     = o.windDir
            observedFog = o.fog
            observedMist = o.mist
            observedDryHaze = o.haze
            // A measured cloud base, which the model does not report at all.
            // -1 stays -1: "no ceiling" is a fact, not a missing value.
            ceiling = o.ceiling
        }

        // What is in sight but not here. Useful for the gust front, which is by
        // definition the part of a storm that arrives before the storm does.
        if o.distanceKm <= Self.cloudReachKm {
            observedVicinity = o.vicinity
        }

        if o.distanceKm <= Self.precipReachKm {
            // The observer's own morphology and form. Recorded in both
            // directions: "not showery" is as useful as "showery", because it
            // is what stops a wall of monsoon CAPE from turning a steady
            // frontal band into an imaginary squall.
            let falling = o.raining || o.snowing
            observedShowery    = falling ? o.showery : false
            observedContinuous = falling ? o.continuousPrecip : false
            observedDrizzle    = falling ? o.drizzle : false
            observedFreezing   = falling ? o.freezing : false
            observedHail       = falling ? o.hail : false
            observedIcePellets = falling ? o.icePellets : false
            observedSquall     = o.squall
            observedBlowingSnow = o.blowingSnow

            if !o.raining && !o.snowing {
                // Nothing is falling. Say so, in every field the scene reads —
                // clearing only `rain` still leaves `precipitation` driving the
                // streaks, which is how a "fixed" dry day kept raining.
                rain = 0; showers = 0; snow = 0; precipitation = 0
            } else {
                // Falling, but the report gives a category rather than a rate.
                // Only raise the model's number to the category's floor, never
                // lower it: the model's millimetres are the better estimate of
                // how hard, the observation is the better answer to whether.
                //
                // Written in mm/HOUR and converted to whatever window
                // `precipitation` is currently accumulating over. Light,
                // moderate and heavy rain are conventionally under 2.5, 2.5 to
                // 7.6, and over 7.6 mm/h; at the usual 15-minute nowcast window
                // these come out as the same 0.25 / 1.2 / 4.0 the scene was
                // tuned against, and stay right when there is no nowcast and
                // the number is an hourly total instead.
                let perHour: Float = o.intensity > 0 ? 16 : o.intensity < 0 ? 1.0 : 4.8
                let floor = perHour * max(15, precipWindow) / 60
                if o.snowing { snow = max(snow, floor * 0.6) }
                if o.raining { rain = max(rain, floor) }
                precipitation = max(precipitation, max(rain, snow))
            }
        }

        if o.distanceKm <= Self.stormReachKm {
            observedThunder = o.thundering
        } else if o.distanceKm <= Self.precipReachKm && !o.thundering {
            // Close enough to rule it out, not close enough to call it.
            observedThunder = false
        }

        observedAt = Date()
        observedFrom = o.stationId
    }
}
