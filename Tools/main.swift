//  render.swift — offscreen still exporter.
//
//  Renders one frame of the scene to a PNG with no window, no permissions and
//  no display. Two jobs: it is how the visuals get checked against the Pi
//  during development, and it is how the app produces the lock-screen still.
//
//    elemental-render --out /tmp/a.png --at 2026-07-29T21:30 --lat 42.37 --lon -72.52
//
//  --at accepts an ISO-ish local time, so any hour of any day can be inspected
//  without waiting for it.

import Foundation
import AppKit
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// ---------------------------------------------------------------- arguments

var args: [String: String] = [:]
do {
    // Boolean flags take no value. Treating every flag as value-taking made
    // "--dock --warmup 2200" swallow the warmup, so every such render ran a
    // single frame and looked empty — a harness bug that reads exactly like an
    // engine bug.
    let argv = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < argv.count {
        guard argv[i].hasPrefix("--") else { i += 1; continue }
        let key = String(argv[i].dropFirst(2))
        let next = (i + 1 < argv.count) ? argv[i + 1] : nil
        if let next, !next.hasPrefix("--") {
            args[key] = next
            i += 2
        } else {
            args[key] = "1"          // bare flag
            i += 1
        }
    }
}
func str(_ k: String, _ d: String) -> String { args[k] ?? d }
func num(_ k: String, _ d: Double) -> Double { args[k].flatMap(Double.init) ?? d }
func int(_ k: String, _ d: Int) -> Int { args[k].flatMap(Int.init) ?? d }

// ---------------------------------------------------------------- --check
//
// Put the model and the observation side by side, and say what the engine
// decided from them.
//
// Everything else in this tool renders. This does not: it is the ground-truth
// harness, and it exists because there was previously nothing to check the
// weather logic AGAINST. "Thunder all afternoon over a sky that was merely
// overcast" was only findable by looking out of a window, which is not a test.
// A METAR is a report of observed conditions at a known point, so it is the
// closest thing to looking out of the window that a program can fetch.
//
//   elemental-render --check --lat 28.4453 --lon 77.5148
//
// ---------------------------------------------------------------- --saverhealth
//
// Why the screen saver is wrong, named specifically.
//
// Every failure the saver has had looks identical from the user's chair — "the
// saver is wrong" — and the causes are not remotely the same: a stale bundle
// after a rebuild, settings that never arrived, weather published for a
// different place, a reading hours old. This separates them.
if args["saverhealth"] != nil {
    let cfg = Config.load()
    let appURL = Bundle.main.bundleURL
    let built = (try? appURL.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
    let h = SaverHealth.check(config: cfg, appBuildDate: built)
    print("saver health for \(cfg.scenePlace.name)")
    if h.isHealthy {
        print("  OK — installed, settings delivered, weather present and current")
    } else {
        for f in h.findings {
            print("  \(f.isRepairable ? "[repairable]" : "[needs you]  ") \(f.summary)")
        }
    }
    exit(0)
}

// ---------------------------------------------------------------- --edr
//
// What headroom this machine's displays actually offer.
//
// Reported rather than assumed, because EDR headroom is not a fixed property
// of a panel: on Apple displays it moves with the brightness slider, with Low
// Power Mode, with thermal state, and with how much of the screen is already
// asking for it. A wallpaper that renders as though it has 16x headroom on a
// machine currently offering 1.0 just clips.
if args["edr"] != nil {
    _ = NSApplication.shared
    for s in NSScreen.screens {
        print("display  \(s.localizedName)  \(Int(s.frame.width))x\(Int(s.frame.height)) @\(s.backingScaleFactor)x")
        print("  headroom now        \(s.maximumExtendedDynamicRangeColorComponentValue)")
        print("  headroom potential  \(s.maximumPotentialExtendedDynamicRangeColorComponentValue)")
        print("  reference           \(s.maximumReferenceExtendedDynamicRangeColorComponentValue)")
        print("  colour space        \(s.colorSpace?.localizedName ?? "nil")")
    }
    if let d = MTLCreateSystemDefaultDevice() {
        print("metal    \(d.name)")
        let formats: [(String, MTLPixelFormat)] = [
            ("rgba16Float", .rgba16Float), ("bgr10a2Unorm", .bgr10a2Unorm),
            ("bgra10_xr", .bgra10_xr), ("rgb10a2Unorm", .rgb10a2Unorm),
        ]
        for (name, fmt) in formats {
            let dsc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: 16, height: 16, mipmapped: false)
            dsc.usage = [.renderTarget, .shaderRead]
            print("  \(name) renderable: \(d.makeTexture(descriptor: dsc) != nil)")
        }
    }
    exit(0)
}

if args["check"] != nil {
    let lat = num("lat", 28.4453), lon = num("lon", 77.5148)
    var done = false
    var model: WeatherState?
    var obs: Observation?
    Task {
        let r = await WeatherService.fetchBoth(lat: lat, lon: lon)
        model = r.model; obs = r.observation; done = true
    }
    let deadline = Date().addingTimeInterval(30)
    while !done && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard let m = model else {
        print("model fetch failed"); exit(1)
    }

    func yn(_ b: Bool) -> String { b ? "YES" : "no" }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")     // or "HH" is a 12-hour clock
    df.dateFormat = "HH:mm"

    print("\nlocation  \(lat), \(lon)      \(df.string(from: Date())) local\n")
    print(String(format: "%-16s %-26s %-26s", ("field" as NSString).utf8String!,
                 ("MODEL (Open-Meteo)" as NSString).utf8String!,
                 ("OBSERVED (METAR)" as NSString).utf8String!))
    print(String(repeating: "-", count: 70))

    func rowOut(_ name: String, _ a: String, _ b: String) {
        let pad = { (s: String, n: Int) in s + String(repeating: " ", count: max(0, n - s.count)) }
        print(pad(name, 16) + pad(a, 26) + b)
    }

    if let o = obs {
        rowOut("station", "—", "\(o.stationId) \(String(format: "%.0fkm", o.distanceKm)), "
                              + "\(String(format: "%.0f", o.age / 60))min old")
        rowOut("cloud total", String(format: "%.0f%%", m.cover), String(format: "%.0f%%", o.coverTotal))
        rowOut("  low", String(format: "%.0f%%", m.cloudLow), String(format: "%.0f%%", o.coverLow))
        rowOut("  mid", String(format: "%.0f%%", m.cloudMid), String(format: "%.0f%%", o.coverMid))
        rowOut("  high", String(format: "%.0f%%", m.cloudHigh), String(format: "%.0f%%", o.coverHigh))
        rowOut("precipitating", yn(m.precipAmount >= 0.05) + String(format: " (%.2fmm)", m.precipAmount),
                                yn(o.raining || o.snowing))
        rowOut("thunder", yn(m.code >= 95 && m.code <= 99)
                          + String(format: " (code %d, CAPE %.0f)", m.code, m.cape),
                          yn(o.thundering))
        rowOut("fog", yn(m.code == 45 || m.code == 48), yn(o.fog))
        rowOut("visibility", String(format: "%.1fkm", m.visibility / 1000),
                             String(format: "%.1fkm", o.visibility / 1000))
        rowOut("wind", String(format: "%.0f km/h @%.0f", m.wind, m.windDir),
                       String(format: "%.0f km/h @%.0f", o.wind, o.windDir))
        rowOut("temp / dew", String(format: "%.0f / %.0f", m.temperature, m.dewPoint),
                             String(format: "%.0f / %.0f", o.temperature, o.dewPoint))
        rowOut("humidity", String(format: "%.0f%%", m.humidity), String(format: "%.0f%%", o.humidity))
        print("\nraw       \(o.raw)")
    } else {
        print("  no usable station within range — the model stands unchecked here")
    }

    var reconciled = m
    if let o = obs { reconciled.reconcile(with: o) }
    print("\nDRAWN     kind=\(reconciled.effectiveKind)  "
        + "cover=\(String(format: "%.0f", reconciled.cover))%  "
        + "rain=\(String(format: "%.2f", reconciled.precipAmount))mm  "
        + "thunder=\(yn(reconciled.isThundering))  fog=\(yn(reconciled.isFoggy))")
    let before = m.effectiveKind
    if before != reconciled.effectiveKind || (m.code >= 95 && m.code <= 99) != reconciled.isThundering {
        print("CHANGED   model alone would have drawn: kind=\(before)  "
            + "thunder=\(yn(m.code >= 95 && m.code <= 99))")
    }
    print("")
    exit(0)
}

// ---------------------------------------------------------------- --calib
//
// What has been learned at a location, and whether the learning works at all.
//
// The second part matters more than it looks. This ships a hand-written ridge
// solver and a hand-written IRLS logistic fit, and if either is wrong it will
// not crash — it will quietly produce confident nonsense and make the sky worse
// than doing nothing. So the fits get checked against data whose true answer is
// known before they are allowed anywhere near the scene.
//
//   elemental-render --calib --lat 28.4453 --lon 77.5148
//   elemental-render --calib --selftest
//
if args["calib"] != nil {
    if args["selftest"] != nil {
        print("\nCALIBRATION SELF-TEST — synthetic data, known answers\n")

        // Deterministic pseudo-random, so a failure is reproducible.
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func rnd() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }

        // ---- 1. cloud. The Noida failure, made synthetic: the model files
        // most of the cover under "high" when it is really low and mid.
        var store = CalibrationStore()
        var samples: [WeatherSample] = []
        for i in 0..<400 {
            var s = WeatherSample(t: Double(i) * 1800)
            s.mLow = rnd() * 40; s.mMid = rnd() * 40; s.mHigh = rnd() * 100
            // truth: two thirds of what the model called high is actually low
            s.oLow  = min(100, max(0, s.mLow  + 0.66 * s.mHigh + (rnd() - 0.5) * 8))
            s.oMid  = min(100, max(0, s.mMid  + 0.20 * s.mHigh + (rnd() - 0.5) * 8))
            s.oHigh = min(100, max(0, 0.10 * s.mHigh + (rnd() - 0.5) * 4))
            s.oPrecip = -1; s.oThunder = -1
            samples.append(s)
        }
        var c = Calibration(); c.key = "selftest"; c.samples = samples
        store.loadForTest(c)
        store.refit()

        func mae(_ pick: (WeatherSample) -> Float, _ raw: (WeatherSample) -> Float,
                 _ fit: Fit) -> (raw: Float, fitted: Float) {
            var r: Float = 0, f: Float = 0
            for s in samples {
                let x: [Float] = [s.mLow / 100, s.mMid / 100, s.mHigh / 100, 1]
                r += abs(raw(s) - pick(s))
                f += abs(max(0, min(100, fit.eval(x) * 100)) - pick(s))
            }
            return (r / Float(samples.count), f / Float(samples.count))
        }
        let lo = mae({ $0.oLow },  { $0.mLow },  store.current.cloudLow)
        let md = mae({ $0.oMid },  { $0.mMid },  store.current.cloudMid)
        let hi = mae({ $0.oHigh }, { $0.mHigh }, store.current.cloudHigh)
        print("cloud — mean absolute error, percentage points")
        print(String(format: "  low    model %5.1f   fitted %5.1f   %@",
                     lo.raw, lo.fitted, lo.fitted < lo.raw * 0.25 ? "PASS" : "FAIL"))
        print(String(format: "  mid    model %5.1f   fitted %5.1f   %@",
                     md.raw, md.fitted, md.fitted < md.raw * 0.25 ? "PASS" : "FAIL"))
        print(String(format: "  high   model %5.1f   fitted %5.1f   %@",
                     hi.raw, hi.fitted, hi.fitted < hi.raw * 0.25 ? "PASS" : "FAIL"))

        // ---- 2. precipitation. A forecast that cries wolf: it claims a
        // trace of rain constantly and is right about a fifth of the time,
        // but when it claims a real amount it is usually right.
        var s2: [WeatherSample] = []
        var wetCount = 0
        for i in 0..<600 {
            var s = WeatherSample(t: Double(i) * 1800)
            s.mPrecip = rnd() < 0.6 ? rnd() * 0.3 : rnd() * 6
            s.mPrecipProb = rnd() * 100
            s.mCodePrecip = s.mPrecip > 0.02 ? 1 : 0
            let pTrue = 1 / (1 + exp(-(4.2 * log(1 + s.mPrecip) - 2.4)))
            s.oPrecip = rnd() < pTrue ? 1 : 0
            if s.oPrecip > 0.5 { wetCount += 1 }
            s.oThunder = -1
            s2.append(s)
        }
        var c2 = Calibration(); c2.key = "selftest"; c2.samples = s2
        store.loadForTest(c2); store.refit()
        let pf = store.current.precip
        print("\nprecipitation — P(actually falling), fitted vs true")
        var worstErr: Float = 0
        for mm in [Float(0.05), 0.1, 0.3, 1.0, 3.0, 6.0] {
            let x: [Float] = [log(1 + mm), 0.5, mm > 0.02 ? 1 : 0, 1]
            let got = pf.probability(x)
            let want = 1 / (1 + exp(-(4.2 * log(1 + mm) - 2.4)))
            worstErr = max(worstErr, abs(got - want))
            print(String(format: "  %5.2fmm   fitted %.2f   true %.2f", mm, got, want))
        }
        print(String(format: "  worst error %.2f   %@   (%d wet of %d)",
                     worstErr, worstErr < 0.12 ? "PASS" : "FAIL", wetCount, s2.count))

        // ---- 3. the guard rails. Too few samples, or only one outcome ever
        // seen, must leave the fit unusable rather than confidently wrong.
        var c3 = Calibration(); c3.key = "selftest"
        c3.samples = Array(s2.prefix(20)); store.loadForTest(c3); store.refit()
        let tooFew = !store.current.precip.usable && !store.current.cloudLow.usable
        var c4 = Calibration(); c4.key = "selftest"
        c4.samples = s2.map { var s = $0; s.oPrecip = 0; return s }
        store.loadForTest(c4); store.refit()
        let oneClass = !store.current.precip.usable
        print("\nguard rails")
        print("  20 samples          fit withheld: \(tooFew ? "PASS" : "FAIL")")
        print("  600 but never wet   fit withheld: \(oneClass ? "PASS" : "FAIL")")
        print("")
        exit(0)
    }

    let lat = num("lat", 28.4453), lon = num("lon", 77.5148)
    let key = CalibrationStore.key(lat: lat, lon: lon)
    print("")
    if let c = CalibrationStore.load(key) {
        print(c.summary)
        var probe = WeatherState()
        probe.cloudLow = 10; probe.cloudMid = 10; probe.cloudHigh = 98
        probe.rain = 0.1; probe.precipitation = 0.1; probe.code = 51
        let s = CalibrationStore()
        s.use(lat: lat, lon: lon)
        if let note = s.apply(to: &probe) { print("\n  on a 10/10/98 drizzle forecast: \(note)") }
        else { print("\n  nothing applies yet") }
    } else {
        print("no calibration for \(key) yet — it is written as observations arrive")
        print("stored under \(CalibrationStore.directory.path)")
    }
    print("")
    exit(0)
}

let outPath = str("out", "/tmp/elemental.png")
let width   = int("width", 1512)
let height  = int("height", 982)
let warmup  = int("warmup", 1)

/// Timezone `--at` is interpreted in. Defaults to the machine's, but the scene
/// is drawn for a location that may be nowhere near it, so `--tz` matters:
/// "13:00" means noon where the sky is, not where the laptop is.
let renderTZ = args["tz"].flatMap(TimeZone.init(identifier:)) ?? .current

let date: Date = {
    guard let s = args["at"] else { return Date() }
    let fmts = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
    for f in fmts {
        let df = DateFormatter()
        df.dateFormat = f
        df.timeZone = renderTZ
        if let d = df.date(from: s) { return d }
    }
    FileHandle.standardError.write("bad --at value: \(s)\n".data(using: .utf8)!)
    exit(2)
}()

// ---------------------------------------------------------------- scene setup

guard let renderer = ElementalRenderer(colorFormat: .rgba8Unorm) else {
    FileHandle.standardError.write("no Metal device / pipeline build failed\n".data(using: .utf8)!)
    exit(1)
}

var state = SceneState()
let lat = num("lat", 42.3732)      // Amherst, MA
let lon = num("lon", -72.5199)
state.facingAz = Float(num("facing", 180))
state.headingMode = str("heading", "custom") == "dynamic" ? .dynamic : .custom
state.gridRows = int("rows", 36)
state.poster = Float(num("poster", 16))
state.reliefDepth = Float(num("depth", 0.5))
state.reliefEmphasis = Float(num("emph", 0.8))
state.lightIntensity = Float(num("light", 0.8))
state.refraction = Float(num("refract", 0.3))
state.dispersion = Float(num("disperse", 0.15))
state.frost = Float(num("frost", 0))
state.splay = Float(num("splay", 0.15))
state.shape  = str("shape", "square") == "dot" ? .dot : .square
state.finish = str("finish", "glass") == "flat" ? .flat : .glass
state.lowFX  = args["lowfx"] != nil

var wx = WeatherState()
wx.code = int("code", 0)
wx.kind = SceneKind.from(code: wx.code)
wx.cover = Float(num("cover", Double(wx.kind == .cloud ? 85 : wx.kind == .partly ? 45 : 5)))
wx.uv = Float(num("uv", 3))
wx.wind = Float(num("wind", 6))
wx.windDir = Float(num("winddir", 180))
wx.rain = Float(num("rain", 0))
wx.snow = Float(num("snow", 0))
wx.visibility = Float(num("vis", 12000))
wx.humidity = Float(num("humid", 50))
wx.temperature = Float(num("temp", 20))
// Dew point defaults from humidity via the Magnus approximation, so a test can
// just say --humid and still get physically consistent evaporation.
wx.dewPoint = Float(num("dew", {
    let t = Double(wx.temperature), rh = max(1.0, Double(wx.humidity))
    let g = (17.27 * t) / (237.3 + t) + log(rh / 100)
    return (237.3 * g) / (17.27 - g)
}()))
// Cover by altitude. Defaults put everything in the low deck, which is what a
// bare --cover used to mean; the depth compositing needs each layer separately
// to be testable, since a moon behind cirrus and a moon behind overcast are the
// two cases that must look nothing alike.
wx.cloudLow  = Float(num("low",  Double(wx.cover)))
wx.cloudMid  = Float(num("mid",  0))
wx.cloudHigh = Float(num("high", 0))
wx.aqi = Float(num("aqi", 30))
wx.smoke = Float(num("smoke", 0))
// ---- the inputs the presentation layer actually keys off.
//
// Morphology, phase and form are derived from these, and until they were
// reachable from the command line there was no way to render a shower and a
// steady band side by side and see whether they look like different weather.
// Every one of them is a quantity somebody measures.
wx.showers   = Float(num("showers", 0))
wx.cape      = Float(num("cape", 0))
wx.liftedIndex = Float(num("li", 0))
wx.gusts     = Float(num("gusts", Double(wx.wind)))
wx.ceiling   = Float(num("ceiling", -1))          // metres AGL; -1 = unmeasured
wx.freezingLevel = Float(num("fzlevel", 3000))
wx.snowDepth = Float(num("snowdepth", 0))
wx.precipProbability = Float(num("prob", 0))
// The measured time structure of the nowcast: how many separate wet runs the
// next four hours hold, which is the direct measurement of "scattered".
if let slots = args["slots"].flatMap(Int.init) {
    wx.nowcastSlots = slots
    wx.nowcastWetSlots = int("wetslots", slots)
    wx.nowcastRuns = int("runs", 1)
    wx.minutesToPrecip = Float(num("tomins", -1))
    wx.minutesSincePrecip = Float(num("sincemins", -1))
    wx.precipNext60 = Float(num("next60", 0))
    wx.precipPast60 = Float(num("past60", 0))
}
// A stand-in station report. These are the present-weather groups a METAR
// carries; the real ones arrive through Observation.swift, and this is only so
// the offscreen harness can exercise each branch deterministically.
if args["obs"] != nil || args["showery"] != nil || args["hail"] != nil
    || args["squall"] != nil || args["drizzleobs"] != nil || args["continuous"] != nil {
    wx.observedAt = Date()
    wx.observedFrom = "SYNTH"
    wx.observedShowery = args["showery"] != nil
    wx.observedContinuous = args["continuous"] != nil
    wx.observedDrizzle = args["drizzleobs"] != nil
    wx.observedHail = args["hail"] != nil
    wx.observedSquall = args["squall"] != nil
    wx.observedIcePellets = args["pellets"] != nil
    wx.observedFreezing = args["freezing"] != nil
}
// --live fetches real conditions for the chosen location, exercising exactly
// the same WeatherService the app and saver use.
if args["live"] != nil {
    // Spin the run loop rather than blocking on a semaphore: the service
    // delivers on the main actor, so blocking the main thread here would
    // deadlock against the very callback we are waiting for.
    var done = false
    let svc = WeatherService()
    svc.onUpdate = { w in wx = w; done = true }
    svc.start(at: Coordinate(latitude: lat, longitude: lon))
    let deadline = Date().addingTimeInterval(20)
    while !done && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if !done { FileHandle.standardError.write("live weather fetch timed out\n".data(using: .utf8)!) }
    svc.stop()
}
state.weather = wx

state.astro = Astro.update(lat: lat, lon: lon, facingAz: Double(state.facingAz), date: date)
renderer.state = state
renderer.resize(width: width, height: height)

// Stand-in furniture so splash behaviour can be exercised offscreen. The real
// hosts derive this from NSScreen and the dock preferences; here it is just a
// bar across the bottom the right sort of size.
// --widget adds a floating rect with clear pane BELOW it, which the dock does
// not have — the dock is flush with the bottom of the display, so anything
// running off its underside runs off the screen. Undersides are where fog and
// dew separate themselves from everything else that falls, and without a
// surface that has one there is no way to see that they do.
if args["dock"] != nil || args["widget"] != nil {
    let W = Float(width), H = Float(height)
    var out: [Surface] = []
    if args["dock"] != nil {
        // Modelled the way Furniture.desktop models it: the dock PANEL, floated
        // above the bottom of the display by its own margin, not the whole
        // reserved strip. Flush with the edge it has no underside, so
        // `shedDrips` can never shed a drop off it and the harness reports a dry
        // dock in a downpour — which is exactly the wrong answer to test against.
        let dockH = H * 0.09, dockW = W * 0.72
        let dockGap = dockH * 0.16
        out.append(Surface(x: (W - dockW) / 2, y: H - dockH + dockGap,
                           w: dockW, h: dockH - dockGap * 2, kind: .dock))
    }
    if args["widget"] != nil {
        let wW = W * 0.26, wH = H * 0.20
        out.append(Surface(x: W * 0.09, y: H * 0.30, w: wW, h: wH, kind: .widget))
        out.append(Surface(x: W * 0.63, y: H * 0.16, w: wW * 0.8, h: wH * 0.7, kind: .widget))
    }
    renderer.surfaces = out
}

// Furniture / pane switches, pinned so the harness does not inherit whatever the
// developer has in their own config.json. `--pane 0` and `--furniture 0` are the
// two that matter: the splash path turned out to be gated on the FIRST of them.
if args["pane"] != nil || args["furniture"] != nil || args["wetdock"] != nil {
    var o = Furniture.Options()
    o.paneWater = num("pane", 1) > 0.5
    o.pane      = Float(num("pane", 1))
    o.dock      = num("wetdock", 1) > 0.5
    o.widgets   = num("wetwidgets", 1) > 0.5
    o.furniture = Float(num("furniture", 1))
    Furniture.pin(o)
}

// ---------------------------------------------------------------- --sheet
//
// A whole day on one page.
//
// Reviewing a timeline one PNG at a time does not work: the faults that matter
// are the ones that only show as a DISCONTINUITY — a colour that jumps between
// two hours, a term that switches on at an altitude threshold, a gradient that
// reverses. Those are invisible in any single frame and obvious when the
// sequence is side by side.
//
//   elemental-render --sheet 12 --from 5 --to 21 --out /tmp/day.png
//
if let n = args["sheet"].flatMap(Int.init), n >= 2 {
    let from = num("from", 5), to = num("to", 21)
    let cols = min(4, n)
    let rows = (n + cols - 1) / cols
    let tw = width / cols, th = height / rows

    let td = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: tw, height: th, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]
    td.storageMode = .shared
    guard let tile = renderer.device.makeTexture(descriptor: td) else { exit(1) }

    let sheetRow = width * 4
    var sheet = [UInt8](repeating: 0, count: sheetRow * height)
    var tileBuf = [UInt8](repeating: 0, count: tw * 4 * th)

    let cal = Calendar(identifier: .gregorian)
    var comps = cal.dateComponents([.year, .month, .day], from: date)
    comps.timeZone = renderTZ

    renderer.resize(width: tw, height: th)
    renderer.fixedTimeStep = 1.0 / 60.0

    for i in 0..<n {
        let hour = from + (to - from) * Double(i) / Double(n - 1)
        comps.hour = Int(hour)
        comps.minute = Int((hour - Double(Int(hour))) * 60)
        guard let t = cal.date(from: comps) else { continue }

        var s = state
        s.astro = Astro.update(lat: lat, lon: lon, facingAz: Double(s.facingAz), date: t)
        renderer.state = s
        // Each tile is its own scene, not a continuation of the last, so the
        // stateful half is re-settled per frame rather than carried across an
        // hour-long jump it was never meant to integrate over.
        for k in 0..<max(1, warmup) {
            renderer.render(to: tile, waitForCompletion: k == max(1, warmup) - 1)
        }
        tileBuf.withUnsafeMutableBytes { p in
            tile.getBytes(p.baseAddress!, bytesPerRow: tw * 4,
                          from: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0)
        }
        let ox = (i % cols) * tw, oy = (i / cols) * th
        for yy in 0..<th {
            let dst = (oy + yy) * sheetRow + ox * 4
            let src = yy * tw * 4
            for xx in 0..<(tw * 4) { sheet[dst + xx] = tileBuf[src + xx] }
        }
        let hh = Int(hour), mm = Int((hour - Double(hh)) * 60)
        print(String(format: "  tile %2d  %02d:%02d  sunAlt %6.1f  moonAlt %6.1f",
                     i, hh, mm, s.astro.sunAlt, s.astro.moonAlt))
    }

    guard let prov = CGDataProvider(data: Data(sheet) as CFData),
          let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: sheetRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dst = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { exit(1) }
    CGImageDestinationAddImage(dst, img, nil)
    _ = CGImageDestinationFinalize(dst)
    print("\(outPath)  \(width)x\(height)  \(cols)x\(rows) tiles")
    exit(0)
}

// ---------------------------------------------------------------- render

let td = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
td.usage = [.renderTarget, .shaderRead]
td.storageMode = .shared
guard let tex = renderer.device.makeTexture(descriptor: td) else {
    FileHandle.standardError.write("texture allocation failed\n".data(using: .utf8)!)
    exit(1)
}

// Warm-up frames let the integrators (rain, droplets) reach a steady state
// before the frame that gets written out. Fixed 60fps steps, so the result is
// deterministic and independent of how fast this loop actually runs.
renderer.fixedTimeStep = 1.0 / 60.0
let total = max(1, warmup)

// --dryfor N: soak the pane for the warm-up, then stop the rain and run N more
// frames. The only way to actually see evaporation work, since while it is
// raining the rate is correctly pinned near zero.
let dryFrames = int("dryfor", 0)

for i in 0..<total {
    renderer.render(to: tex, waitForCompletion: dryFrames == 0 && i == total - 1)
}
if dryFrames > 0 {
    var clear = renderer.state.weather
    clear.code = 0; clear.kind = .sun
    clear.rain = 0; clear.showers = 0; clear.snow = 0; clear.precipitation = 0
    clear.cover = 10
    renderer.state.weather = clear
    if args["debug"] != nil {
        print("  rain off  " + renderer.debugCounts)
    }
    for i in 0..<dryFrames {
        renderer.render(to: tex, waitForCompletion: i == dryFrames - 1)
    }
}

if args["debug"] != nil { print("  sim       " + renderer.debugCounts) }

// ---------------------------------------------------------------- write PNG

let rowBytes = width * 4
var pixels = [UInt8](repeating: 0, count: rowBytes * height)
pixels.withUnsafeMutableBytes { p in
    tex.getBytes(p.baseAddress!, bytesPerRow: rowBytes,
                 from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
}

// ---------------------------------------------------------------- --water
//
// What the water simulation actually did, as numbers.
//
// The splash path is stateful and needs hundreds of warm-up frames, so a still
// frame cannot distinguish "no splashes happened" from "splashes happened and
// are invisible". Those have completely different causes and the counters
// separate them in one line.
//
// AFTER the render, necessarily. Printed before it, every counter reads zero —
// including the precipitation rate — which looks exactly like a dead simulation
// and is only an empty one.
//
//   elemental-render --kind rain --rain 8 --dock --widget --warmup 900 --water
if args["water"] != nil {
    print(renderer.waterDebug)
}

// ---------------------------------------------------------------- --probe
//
// Sky colour, as numbers, down the middle of the frame.
//
// Colour work by eye does not converge — "too warm" and "too bright" are not
// quantities, and the mosaic's bevel means no two adjacent pixels agree anyway.
// This averages a horizontal band per sample row so the cell relief cancels
// out, and reports what the sky actually IS at that height.
if args["probe"] != nil {
    print("  probe     screen-y   R   G   B    (row mean, cell relief averaged out)")
    let rows = 9
    for k in 0..<rows {
        let y = min(height - 1, (height - 1) * k / (rows - 1))
        var r = 0, g = 0, b = 0, n = 0
        // A whole row, so the per-cell bevel and the mosaic grout average away.
        for x in stride(from: 0, to: width, by: 3) {
            let i = y * rowBytes + x * 4
            r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2]); n += 1
        }
        let yf = Double(y) / Double(height - 1)
        print(String(format: "            %4.2f    %3d %3d %3d", yf, r / n, g / n, b / n))
    }
    // Column-to-column variation, averaged down the frame. This is the number
    // for "brutal vertical lines": a sky with no vertical structure has a tiny
    // value here, and banding shows up as a large one.
    var colMean = [Double](repeating: 0, count: width)
    for x in 0..<width {
        var s = 0.0
        for y in stride(from: 0, to: height, by: 2) {
            let i = y * rowBytes + x * 4
            s += Double(Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
        }
        colMean[x] = s / Double((height + 1) / 2)
    }
    // Difference between neighbouring columns one cell apart, which is the
    // scale a band would live at. Compared against the same measure down rows.
    let cell = max(1, Int(Double(height) / Double(state.gridRows)))
    var vBand = 0.0, m = 0
    for x in cell..<width { vBand += abs(colMean[x] - colMean[x - cell]); m += 1 }
    print(String(format: "  banding   vertical %.2f  (mean |Δ| between columns one cell apart)",
                 vBand / Double(max(1, m))))
}

// ---------------------------------------------------------------- foreground
//
// Draw the furniture ON TOP, the way the user actually sees it.
//
// The wallpaper renders BEHIND the dock and the widgets — that is the whole
// mechanism, and it is why a splash is aimed at a surface's TOP EDGE and has to
// travel upward into open sky to be seen at all. The harness was compositing
// none of that, so every splash render was a picture of a scene with the
// occluders missing: water drawn inside the dock's rectangle looked perfectly
// visible here and is, in reality, behind the dock.
//
// So paint the surfaces in as opaque blocks. Anything still visible above their
// top edges is what the user gets; anything that disappears under one was never
// going to be seen. `--furnfg 0` turns it off.
if (args["dock"] != nil || args["widget"] != nil), num("furnfg", 1) > 0.5 {
    for s in renderer.surfaces {
        let x0 = max(0, Int(s.left)), x1 = min(width, Int(s.right))
        let y0 = max(0, Int(s.top)),  y1 = min(height, Int(s.bottom))
        guard x1 > x0, y1 > y0 else { continue }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let o = y * rowBytes + x * 4
                // A flat translucent slab, dark enough to read as furniture and
                // light enough that a splash overlapping its lip is still legible.
                pixels[o + 0] = UInt8(Int(pixels[o + 0]) * 22 / 100 + 30)
                pixels[o + 1] = UInt8(Int(pixels[o + 1]) * 22 / 100 + 32)
                pixels[o + 2] = UInt8(Int(pixels[o + 2]) * 22 / 100 + 36)
            }
        }
    }
}

guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let img = CGImage(width: width, height: height,
                        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false,
                        intent: .defaultIntent) else {
    FileHandle.standardError.write("CGImage creation failed\n".data(using: .utf8)!)
    exit(1)
}

let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("cannot write \(outPath)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("PNG encode failed\n".data(using: .utf8)!)
    exit(1)
}

let f = DateFormatter()
// en_US_POSIX or "HH" silently becomes a 12-hour clock on a machine set to
// 12-hour time, and 23:53 prints as 11:53.
f.locale = Locale(identifier: "en_US_POSIX")
f.dateFormat = "yyyy-MM-dd HH:mm zzz"; f.timeZone = renderTZ
print("""
\(outPath)  \(width)x\(height)
  time      \(f.string(from: date))
  location  \(lat), \(lon)  facing \(Int(state.facingAz))°
  sun       alt \(String(format: "%.1f", state.astro.sunAlt))°  az \(String(format: "%.1f", state.astro.sunAz))°
  moon      alt \(String(format: "%.1f", state.astro.moonAlt))°  az \(String(format: "%.1f", state.astro.moonAz))°  illum \(String(format: "%.0f", state.astro.moonIllum))%  phase \(String(format: "%.2f", state.astro.moonPhaseN))
  stars     \(state.astro.stars.count) above horizon and in view
  style     \(state.shape) / \(state.finish)   grid \(state.gridRows) rows
  weather   \(state.weather.effectiveKind)  cover \(String(format: "%.0f", state.weather.cover))% (lo \(String(format: "%.0f", state.weather.cloudLow)) mid \(String(format: "%.0f", state.weather.cloudMid)) hi \(String(format: "%.0f", state.weather.cloudHigh)))  precip \(String(format: "%.2f", state.weather.precipAmount))mm  \(state.weather.observedFrom.map { "via " + $0 } ?? "model only")
""")
