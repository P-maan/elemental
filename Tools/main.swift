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
state.glassAmplify = Float(num("glass", 0.3))
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
if args["dock"] != nil {
    let W = Float(width), H = Float(height)
    let dockH = H * 0.09, dockW = W * 0.72
    renderer.surfaces = [
        Surface(x: (W - dockW) / 2, y: H - dockH, w: dockW, h: dockH, kind: .dock)
    ]
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
  moon      alt \(String(format: "%.1f", state.astro.moonAlt))°  illum \(String(format: "%.0f", state.astro.moonIllum))%  phase \(String(format: "%.2f", state.astro.moonPhaseN))
  stars     \(state.astro.stars.count) above horizon and in view
  style     \(state.shape) / \(state.finish)   grid \(state.gridRows) rows
  weather   \(state.weather.effectiveKind)  cover \(String(format: "%.0f", state.weather.cover))% (lo \(String(format: "%.0f", state.weather.cloudLow)) mid \(String(format: "%.0f", state.weather.cloudMid)) hi \(String(format: "%.0f", state.weather.cloudHigh)))  precip \(String(format: "%.2f", state.weather.precipAmount))mm  \(state.weather.observedFrom.map { "via " + $0 } ?? "model only")
""")
