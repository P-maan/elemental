//  Weather.swift — live conditions for the scene.
//
//  The renderer already draws every element the Pi does: cloud deck, rain and
//  snow streaks, fog, thunder and its flash, AQI haze, wildfire smoke, wind
//  drift, humidity haze, the glass layer's droplets and vortices. None of it
//  showed, because nothing filled WeatherState — it sat on its defaults, which
//  describe a clear calm day. This is that missing half.
//
//  Same sources and the same derivations as roomstand.py:1273-1325, so the Mac
//  and the Pi agree about the weather rather than merely looking similar:
//
//    api.open-meteo.com          current conditions + a 15-minute nowcast
//    air-quality-api.open-meteo  US AQI, PM2.5/PM10, aerosol optical depth
//
//  No API key, no account, and it fails soft: a failed fetch leaves the last
//  good reading in place rather than snapping the sky back to clear.

import Foundation

final class WeatherService {

    /// Delivered on the main queue whenever a fresh reading lands.
    var onUpdate: ((WeatherState) -> Void)?

    private var timer: Timer?
    private var place: Coordinate?
    private(set) var latest = WeatherState()
    private(set) var lastSuccess: Date?
    private var failures = 0
    /// Monotonic request id, so a reply can be matched to the request that is
    /// still wanted.
    private var requestSeq: UInt64 = 0

    /// Open-Meteo updates on roughly a 15-minute cadence; polling faster only
    /// wastes requests. Failures back off so a flaky connection does not hammer
    /// the API.
    private var interval: TimeInterval { failures == 0 ? 600 : min(3600, 600 * pow(2, Double(failures))) }

    func start(at coordinate: Coordinate) {
        // A location change should refetch immediately, not at the next tick.
        let changed = place != coordinate
        place = coordinate
        if changed {
            // Invalidate anything in flight for the previous place.
            requestSeq &+= 1
            fetchNow()
        }
        guard timer == nil || changed else { return }
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetchNow()
        }
    }

    func fetchNow() {
        guard let p = place else { return }
        // Stamp the request so a slow reply for a place we have since left can
        // be recognised and dropped.
        requestSeq &+= 1
        let seq = requestSeq
        Task { [weak self] in
            guard let self else { return }
            let result = await Self.fetch(lat: p.latitude, lon: p.longitude)
            await MainActor.run {
                // A request in flight when the city changes must NOT be applied:
                // switching from a wet city to a dry one while its reply was
                // still on the wire painted the old city's rain onto the new
                // one's sky. Both the sequence and the coordinate are checked —
                // the sequence catches reordering, the coordinate catches a
                // change and change-back.
                guard seq == self.requestSeq, self.place == p else {
                    NSLog("Elemental: discarded stale weather for %.3f,%.3f", p.latitude, p.longitude)
                    return
                }
                if let w = result {
                    self.latest = w
                    self.lastSuccess = Date()
                    self.failures = 0
                    self.onUpdate?(w)
                } else {
                    // Keep the last good reading. A dropped request should not
                    // wipe the sky clear.
                    self.failures += 1
                    NSLog("Elemental: weather fetch failed (%d in a row)", self.failures)
                }
                self.schedule()
            }
        }
    }

    // MARK: - Fetch

    static func fetch(lat: Double, lon: Double) async -> WeatherState? {
        async let wx = fetchConditions(lat: lat, lon: lon)
        async let air = fetchAirQuality(lat: lat, lon: lon)
        // The observation is fetched alongside, not instead. It covers only
        // what an observer can see; the model still supplies UV, CAPE and
        // precipitation rate, none of which appear in a METAR.
        async let obs = ObservationService.fetch(lat: lat, lon: lon)

        guard var w = await wx else { _ = await obs; return nil }
        if let a = await air {
            w.aqi = a.aqi
            w.smoke = a.smoke
            w.pm25 = a.pm25
            w.pm10 = a.pm10
        }
        if let o = await obs {
            // Record BEFORE reconciling. Afterwards `w` holds the observation's
            // own numbers, and a fit trained on that learns the identity and
            // corrects nothing.
            await MainActor.run {
                calibration.use(lat: lat, lon: lon)
                calibration.record(model: w, observation: o)
            }
            w.reconcile(with: o)
            NSLog("Elemental: obs %@", o.summary)
        } else {
            // No station, or no network. This is where the learning earns its
            // keep: the live check is unavailable, but how the model errs here
            // was learned while it was.
            let note: String? = await MainActor.run {
                calibration.use(lat: lat, lon: lon)
                return calibration.apply(to: &w)
            }
            if let note { NSLog("Elemental: no observation — calibrated: %@", note) }
        }
        return w
    }

    /// Learned corrections for the current location. Shared, because the app
    /// and its offscreen exporters all draw the same place and should all
    /// benefit from the same history.
    @MainActor static let calibration = CalibrationStore()

    /// Both readings, unreconciled — for the comparison harness, which has to
    /// show what each source said before anything was decided between them.
    static func fetchBoth(lat: Double, lon: Double)
        async -> (model: WeatherState?, observation: Observation?) {
        async let wx = fetchConditions(lat: lat, lon: lon)
        async let air = fetchAirQuality(lat: lat, lon: lon)
        async let obs = ObservationService.fetch(lat: lat, lon: lon)
        var m = await wx
        if let a = await air, m != nil {
            m!.aqi = a.aqi; m!.smoke = a.smoke; m!.pm25 = a.pm25; m!.pm10 = a.pm10
        }
        return (m, await obs)
    }

    private static func fetchConditions(lat: Double, lon: Double) async -> WeatherState? {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            // Everything the engine can draw with. Cloud is split by altitude
            // because a single cover number cannot tell thin high cirrus from a
            // low overcast, and they look nothing alike.
            .init(name: "current", value: [
                "weather_code", "is_day",
                "cloud_cover", "cloud_cover_low", "cloud_cover_mid", "cloud_cover_high",
                "temperature_2m", "apparent_temperature", "dew_point_2m", "relative_humidity_2m",
                "pressure_msl", "surface_pressure",
                "wind_speed_10m", "wind_direction_10m", "wind_gusts_10m",
                "precipitation", "rain", "showers", "snowfall",
                "visibility", "uv_index",
            ].joined(separator: ",")),
            // Convection lives in the hourly block. CAPE and lifted index are
            // what let a storm flash at a believable rate instead of on a timer.
            .init(name: "hourly", value: [
                "cape", "lifted_index", "convective_inhibition",
                "freezing_level_height", "boundary_layer_height",
                "snow_depth", "precipitation_probability",
            ].joined(separator: ",")),
            // 15-minute nowcast: the freshest slot overrides current precip and
            // code, so a shower that just started shows up now, not in 10 min.
            .init(name: "minutely_15", value: "precipitation,rain,snowfall,weather_code"),
            .init(name: "daily", value: "uv_index_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
        ]
        guard let url = c.url, let json = await getJSON(url) else { return nil }
        guard let cur = json["current"] as? [String: Any] else { return nil }

        func d(_ k: String, _ fallback: Double = 0) -> Double { (cur[k] as? NSNumber)?.doubleValue ?? fallback }

        var w = WeatherState()
        w.code            = Int(d("weather_code"))
        w.isDay           = d("is_day", 1) > 0.5
        w.cover           = Float(d("cloud_cover", 5))
        w.cloudLow        = Float(d("cloud_cover_low"))
        w.cloudMid        = Float(d("cloud_cover_mid"))
        w.cloudHigh       = Float(d("cloud_cover_high"))
        w.temperature     = Float(d("temperature_2m", 20))
        w.apparent        = Float(d("apparent_temperature", 20))
        w.dewPoint        = Float(d("dew_point_2m", 10))
        w.humidity        = Float(d("relative_humidity_2m", 50))
        w.pressureMSL     = Float(d("pressure_msl", 1013))
        w.surfacePressure = Float(d("surface_pressure", 1013))
        w.wind            = Float(d("wind_speed_10m"))
        w.gusts           = Float(d("wind_gusts_10m", d("wind_speed_10m")))
        w.windDir         = Float(d("wind_direction_10m", 180))
        w.precipitation   = Float(d("precipitation"))
        w.rain            = Float(d("rain"))
        w.showers         = Float(d("showers"))
        w.snow            = Float(d("snowfall"))
        w.visibility      = Float(d("visibility", 12000))
        w.uv              = Float(d("uv_index"))

        // ---- hourly block, at the slot covering now
        if let hourly = json["hourly"] as? [String: Any],
           let times = hourly["time"] as? [String],
           let nowStr = cur["time"] as? String {
            let hourKey = String(nowStr.prefix(13))          // yyyy-MM-dd'T'HH
            let idx = times.firstIndex { $0.hasPrefix(hourKey) } ?? 0
            func h(_ k: String, _ fallback: Float) -> Float {
                guard let a = hourly[k] as? [Any], idx < a.count,
                      let v = (a[idx] as? NSNumber)?.floatValue else { return fallback }
                return v
            }
            w.cape                 = h("cape", 0)
            w.liftedIndex          = h("lifted_index", 0)
            w.convectiveInhibition = h("convective_inhibition", 0)
            w.freezingLevel        = h("freezing_level_height", 3000)
            w.boundaryLayer        = h("boundary_layer_height", 800)
            w.snowDepth            = h("snow_depth", 0)
            w.precipProbability    = h("precipitation_probability", 0)
        }

        // ---- nowcast override
        if let mn = json["minutely_15"] as? [String: Any],
           let times = mn["time"] as? [String],
           let nowStr = cur["time"] as? String {
            var best = -1
            for (i, t) in times.enumerated() where t <= nowStr { best = i }
            if best >= 0 {
                func slot(_ k: String) -> Double? {
                    guard let a = mn[k] as? [Any], best < a.count else { return nil }
                    return (a[best] as? NSNumber)?.doubleValue
                }
                if let v = slot("weather_code")  { w.code = Int(v) }
                if let v = slot("rain")          { w.rain = Float(v) }
                if let v = slot("snowfall")      { w.snow = Float(v) }
                if let v = slot("precipitation") {
                    w.precipitation = Float(v)
                    if w.rain == 0, w.snow == 0 { w.rain = Float(v) }
                }
            }
        }

        // UV goes to zero overnight; fall back to the day's peak so the light
        // pockets do not collapse entirely at dusk.
        if w.uv == 0, let daily = json["daily"] as? [String: Any],
           let arr = daily["uv_index_max"] as? [Any], let f = arr.first as? NSNumber {
            w.uv = Float(f.doubleValue)
        }

        w.kind = SceneKind.from(code: w.code)
        return w
    }

    /// Wildfire smoke is heavy aerosol AND fine-particle dominated. Both have to
    /// be high, which is what keeps coarse dust — routine around Delhi and
    /// Noida — from turning the sky orange (roomstand.py:1315).
    private static func fetchAirQuality(lat: Double, lon: Double)
        async -> (aqi: Float, smoke: Float, pm25: Float, pm10: Float)? {
        var c = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "us_aqi,pm2_5,pm10,aerosol_optical_depth,dust,uv_index"),
        ]
        guard let url = c.url, let json = await getJSON(url),
              let cur = json["current"] as? [String: Any] else { return nil }
        func d(_ k: String) -> Double { (cur[k] as? NSNumber)?.doubleValue ?? 0 }

        let aqi = d("us_aqi"), pm25 = d("pm2_5"), pm10 = d("pm10"), aod = d("aerosol_optical_depth")
        let aodF = max(0, min(1, (aod - 0.45) / 0.95))
        let fineRatio = pm25 / max(1, pm25 + pm10)
        let fineF = max(0, min(1, (fineRatio - 0.52) / 0.30))
        return (Float(aqi), Float(aodF * fineF), Float(pm25), Float(pm10))
    }

    private static func getJSON(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}
