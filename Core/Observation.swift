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
    var fog = false
    var haze = false
    /// -1 light, 0 moderate, +1 heavy. Only meaningful while precipitating.
    var intensity: Int = 0

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
        if raining    { wx.append(intensity > 0 ? "heavy rain" : intensity < 0 ? "light rain" : "rain") }
        if snowing    { wx.append("snow") }
        if fog        { wx.append("fog") }
        if haze       { wx.append("haze") }
        if wx.isEmpty { wx.append("no precip") }
        return String(format: "%@ %.0fkm %.0fmin ago | cloud %.0f%% (lo %.0f mid %.0f hi %.0f) | vis %.1fkm | %@",
                      stationId, distanceKm, age / 60,
                      coverTotal, coverLow, coverMid, coverHigh,
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
        for l in layers {
            let cover = (l["cover"] as? String) ?? ""
            let p = pct(cover)
            guard p > 0 else { continue }
            // A vertical-visibility report has no base; treat it as ground level.
            let base = (l["base"] as? NSNumber)?.floatValue ?? 0
            if base < 6500        { lo  = max(lo,  p) }
            else if base < 20000  { mid = max(mid, p) }
            else                  { hi  = max(hi,  p) }
        }
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
    private static func decodePresentWeather(_ s: String, into o: inout Observation) {
        guard !s.isEmpty else { return }
        let up = s.uppercased()
        for token in up.split(separator: " ") {
            var t = String(token)
            // Vicinity: something is going on, but not over the station. Keep
            // the haze/fog reading but do not claim it is raining here.
            let vicinity = t.hasPrefix("VC")
            if vicinity { t.removeFirst(2) }
            if t.hasPrefix("-") { o.intensity = -1; t.removeFirst() }
            else if t.hasPrefix("+") { o.intensity = 1; t.removeFirst() }

            if t.contains("TS") { o.thundering = !vicinity }
            if !vicinity {
                if t.contains("RA") || t.contains("DZ") { o.raining = true }
                if t.contains("SN") || t.contains("SG") || t.contains("IC") { o.snowing = true }
                if t.contains("GR") || t.contains("GS") || t.contains("PL") { o.raining = true }
                if t.contains("UP") { o.raining = true }     // unidentified precipitation
            }
            if t.contains("FG") || t.contains("BR") { o.fog = true }
            if t.contains("HZ") || t.contains("FU") || t.contains("DU")
                || t.contains("SA") || t.contains("PY") { o.haze = true }
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
        }

        if o.distanceKm <= Self.precipReachKm {
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
                let floor: Float = o.intensity > 0 ? 4.0 : o.intensity < 0 ? 0.25 : 1.2
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
