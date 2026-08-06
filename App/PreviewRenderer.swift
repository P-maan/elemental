//  PreviewRenderer.swift — the settings window's thumbnails.
//
//  Every advanced control in Settings used to be a word and a number. "Splay",
//  "Dispersion", "Emphasis" mean nothing to anyone who has not read the shader,
//  and a paragraph of prose underneath is a worse answer than a picture. So each
//  option now carries a small render of the scene AS THAT OPTION WOULD DRAW IT,
//  and the control is chosen by looking rather than by reading.
//
//  The asset that makes this possible is that `ElementalRenderer` is completely
//  headless: no window, no drawable, no permissions — it is the same path the
//  lock-screen still uses (see LockStill.swift). A thumbnail is therefore just
//  "build a SceneState, render it small, read the texture back".
//
//  PERFORMANCE IS THE WHOLE DESIGN HERE. Settings has a history of lag: every
//  control change used to do a JSON write, a preferences sync and a full-screen
//  offscreen render, synchronously, once per mouse-move. That was fixed by
//  splitting cheap live updates from expensive work debounced by 0.45s, and
//  nothing in this file may undo it. So:
//
//    * ONE renderer per pixel size, shared by every thumbnail of that size —
//      not one per control. Building a renderer compiles the shader library,
//      which is by far the most expensive thing here, and it happens at most
//      three times per launch, lazily, off the main thread.
//    * Renders happen on a serial background queue. The main thread never
//      blocks on Metal, and a slider never waits for a picture.
//    * Results are cached by the exact parameters that produced them, so
//      dragging a slider back to a value you have already seen costs nothing.
//    * Requests are coalesced per control: while a drag is in flight only the
//      NEWEST request for a given thumbnail is rendered and every superseded
//      one is dropped before it touches the GPU. A 60-events-per-second drag
//      therefore costs one render per render, not sixty.
//
//  See `stats` for the counters, which the scratchpad harness prints.

import AppKit
import Metal
import CoreGraphics

// MARK: - Spec
//
// Everything that decides what a thumbnail looks like, and nothing else — this
// is the cache key, so it must be exact, hashable, and free of float noise.
// Continuous values are held as whole percent / whole degrees / tenths of a
// degree for that reason: two configs that differ in the ninth decimal are the
// same picture and must be the same key.

struct PreviewSpec: Hashable {

    /// Pixel size of the render. Points are half this — thumbnails are drawn at
    /// 2x so they stay crisp on Retina without ever being large.
    var width: Int = 132
    var height: Int = 84

    var shape: MosaicShape = .square
    var finish: MosaicFinish = .glass
    var gridRows: Int = 36

    // Relief, 0...100.
    var depth = 50
    var emphasis = 80
    var light = 80
    var refraction = 30
    var dispersion = 15
    var frost = 0
    var splay = 15

    /// Whole degrees.
    var facingAz = 180
    var dynamic = false

    /// Draw this preview on a moonlit night instead of in the afternoon.
    ///
    /// Measured, not guessed. Refraction, dispersion and frost all act on what
    /// is BEHIND a block, so over a smooth afternoon gradient a block a few
    /// pixels off looks exactly like the block in front of it and all three
    /// sliders render three identical thumbnails. Against a full moon — a hard
    /// bright disc on a dark sky — frost's 0%-to-100% difference goes from 0.13
    /// to 0.39 at the 99th percentile, and dispersion's from 0.005 to 0.008
    /// mean. So the glass controls are previewed at night, which is also simply
    /// when glass is worth looking at.
    ///
    /// Refraction stays under 0.05 either way; see the note in Settings.swift.
    var nightMoon = false

    /// Tenths of a degree. The sky geometry is genuinely drawn for the chosen
    /// city, so the preview is not lying about where the sun is.
    var latT = 424
    var lonT = -725

    static func pct(_ d: Double) -> Int { Int((max(0, min(1, d)) * 100).rounded()) }

    /// The desktop's settings.
    static func desktop(_ c: Config, pixels: CGSize) -> PreviewSpec {
        var s = PreviewSpec()
        s.width = Int(pixels.width); s.height = Int(pixels.height)
        s.shape = c.shape; s.finish = c.finish; s.gridRows = c.gridRows
        s.depth = pct(c.reliefDepth)
        s.emphasis = pct(c.emphasis)
        s.light = pct(c.lightIntensity)
        s.refraction = pct(c.refraction)
        s.dispersion = pct(c.dispersion)
        s.frost = pct(c.frost)
        s.splay = pct(c.splay)
        s.facingAz = Int(c.facingAz.rounded())
        s.dynamic = c.headingMode == .dynamic
        s.place(c.effectivePlace)
        return s
    }

    /// One surface's settings, over the desktop's relief — relief is not
    /// per-surface, by design (see Config.SurfaceStyle).
    static func surface(_ c: Config, _ st: Config.SurfaceStyle, pixels: CGSize) -> PreviewSpec {
        var s = desktop(c, pixels: pixels)
        s.shape = st.shape; s.finish = st.finish; s.gridRows = st.gridRows
        s.facingAz = Int(st.facingAz.rounded())
        s.dynamic = st.headingMode == .dynamic
        if let n = st.scenePlaceName, let p = c.allPlaces.first(where: { $0.name == n }) {
            s.place(p)
        }
        return s
    }

    private mutating func place(_ p: Place) {
        // Clamped away from the poles: the canonical preview instant below is
        // chosen so the sun is up, and inside the polar circles that cannot be
        // guaranteed. A thumbnail that is uniformly black shows nothing about
        // the option it is meant to be demonstrating.
        latT = Int((max(-55, min(55, p.latitude)) * 10).rounded())
        lonT = Int((max(-180, min(180, p.longitude)) * 10).rounded())
    }

    var latitude: Double { Double(latT) / 10 }
    var longitude: Double { Double(lonT) / 10 }

    /// The instant every thumbnail is drawn at.
    ///
    /// Fixed rather than "now", for three reasons: a preview rendered at 3am is
    /// a black rectangle and demonstrates nothing; two thumbnails compared side
    /// by side must differ ONLY in the option being compared; and a cache key
    /// containing the wall clock never hits. Equinox, mid-afternoon solar time,
    /// so the sun is up at any latitude this clamps to and low enough to throw
    /// the side-light that makes relief legible. Derived from longitude so it is
    /// mid-afternoon where the sky is, not where the laptop is.
    var instant: Date {
        var c = DateComponents()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        if nightMoon {
            // Full moon, high and better than 99% lit at this instant, which is
            // the hard bright edge the glass sliders need to be visible at all.
            c.year = 2026; c.month = 3; c.day = 3; c.hour = 4
            let t = cal.date(from: c) ?? Date(timeIntervalSince1970: 1_772_337_600)
            return t.addingTimeInterval(-longitude / 15 * 3600)
        }
        c.year = 2026; c.month = 3; c.day = 20; c.hour = 12
        let noonUTC = cal.date(from: c) ?? Date(timeIntervalSince1970: 1_774_008_000)
        return noonUTC.addingTimeInterval(-longitude / 15 * 3600 + 3.4 * 3600)
    }

    /// The scene this spec describes, ready to hand to the renderer.
    var sceneState: SceneState {
        var s = SceneState()
        s.shape = shape
        s.finish = finish
        s.gridRows = gridRows
        s.facingAz = Float(facingAz)
        // A night preview exists to show the moon through the glass, so the
        // moon has to be ON SCREEN — dynamic keeps whatever is up centred. A
        // custom heading would point the view at an empty patch of sky about
        // half the time and demonstrate nothing.
        s.headingMode = (dynamic || nightMoon) ? .dynamic : .custom
        s.reliefDepth = Float(depth) / 100
        s.reliefEmphasis = Float(emphasis) / 100
        s.lightIntensity = Float(light) / 100
        s.refraction = Float(refraction) / 100
        s.dispersion = Float(dispersion) / 100
        s.frost = Float(frost) / 100
        s.splay = Float(splay) / 100

        // A broken sky rather than a clear one. Relief, refraction, dispersion
        // and frost all need something with EDGES to act on; over a clean
        // gradient every one of the seven sliders looks identical, which is
        // exactly the failure this whole feature exists to fix.
        var w = WeatherState()
        if nightMoon {
            // Clear, so nothing is between the moon and the wall.
            w.code = 0
            w.kind = .sun
            w.cover = 4
            w.cloudLow = 2; w.cloudMid = 2; w.cloudHigh = 4
            w.wind = 8; w.gusts = 12; w.windDir = 250
            w.uv = 0; w.visibility = 25000
            w.temperature = 9; w.dewPoint = 4; w.humidity = 70
        } else {
            w.code = 2
            w.kind = .partly
            w.cover = 52
            w.cloudLow = 24; w.cloudMid = 26; w.cloudHigh = 30
            w.wind = 11; w.gusts = 15; w.windDir = 250
            w.uv = 4; w.visibility = 20000
            w.temperature = 17; w.dewPoint = 8; w.humidity = 55
        }
        s.weather = w

        s.astro = Astro.update(lat: latitude, lon: longitude,
                               facingAz: Double(facingAz), date: instant)
        return s
    }
}

// MARK: - The pool

final class ScenePreview {

    static let shared = ScenePreview()

    // Exactly three pixel sizes, so there are at most three renderers and a
    // thumbnail almost never triggers a `resize()` (which reallocates the cell
    // textures AND re-randomises the drifting light pockets, so two tiles that
    // straddle one are lit differently and stop being comparable).
    /// The hero. Deliberately a FIXED size, centred in the pane rather than
    /// stretched to fill it: 1:1 on a Retina display, so the cell edges stay
    /// hard. Stretching an 800px render across a wide window would upscale the
    /// one thing the preview exists to show. 400k pixels, ~19ms a frame, and
    /// that cost does not grow when the user resizes the window.
    static let large  = CGSize(width: 800, height: 500)   // 400x250 pt
    /// Option tiles — shape, finish, density.
    static let medium = CGSize(width: 240, height: 150)   // 120x75 pt
    /// The low/medium/high strip beside a slider.
    static let small  = CGSize(width: 132, height: 84)    //  66x42 pt

    /// One thumbnail at a time, off the main thread, forever.
    private let queue = DispatchQueue(label: "com.prakritmaan.elemental.preview",
                                      qos: .userInitiated)
    private let lock = NSLock()

    // ---- shared state, under `lock`
    private var cache: [PreviewSpec: NSImage] = [:]
    private var order: [PreviewSpec] = []
    private var cachedPixels = 0
    /// ~48MB of thumbnails at 4 bytes a pixel. Small tiles are 11k pixels, so
    /// this holds hundreds of them and still bounds the large ones.
    private static let pixelBudget = 12_000_000
    /// Newest request per control. A request that is no longer the newest for
    /// its control is dropped before it reaches the GPU.
    private var wanted: [ObjectIdentifier: PreviewSpec] = [:]

    struct Stats { var renders = 0, hits = 0, dropped = 0; var seconds = 0.0 }
    private var _stats = Stats()
    var stats: Stats { lock.lock(); defer { lock.unlock() }; return _stats }

    // ---- queue-only state
    private var device: MTLDevice?
    private var units: [Int: Unit] = [:]

    /// One renderer and its readback texture, for one pixel size.
    private final class Unit {
        let renderer: ElementalRenderer
        let texture: MTLTexture
        /// Heading of the last frame this renderer drew. The renderer eases the
        /// facing with a ~20s time constant, so a preview at a new heading needs
        /// one big time step to settle before the frame we keep — otherwise the
        /// picture lags the slider by twenty simulated seconds, i.e. forever.
        var lastHeading: Int?
        init(renderer: ElementalRenderer, texture: MTLTexture) {
            self.renderer = renderer
            self.texture = texture
        }
    }

    private init() {}

    // MARK: - Public API

    /// The image for `spec` if it has already been rendered. Main thread.
    func cached(_ spec: PreviewSpec) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[spec]
    }

    /// Ask for a thumbnail.
    ///
    /// `slot` identifies the control asking — pass `ObjectIdentifier(theView)`.
    /// Only the most recent spec per slot is ever rendered, which is what makes
    /// a drag cost one render per render instead of one per mouse event.
    ///
    /// A cache hit calls back synchronously; everything else calls back on the
    /// main thread once the picture exists. Callers must tolerate results
    /// arriving for superseded specs — they are intermediate frames of a drag
    /// and showing them is what makes the preview track the control.
    func request(_ spec: PreviewSpec, slot: ObjectIdentifier,
                 completion: @escaping (NSImage) -> Void) {
        lock.lock()
        if let hit = cache[spec] {
            _stats.hits += 1
            lock.unlock()
            completion(hit)
            return
        }
        wanted[slot] = spec
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = self.wanted[slot] != spec
            let hit = self.cache[spec]
            if stale { self._stats.dropped += 1 }
            self.lock.unlock()

            if let hit {
                DispatchQueue.main.async { completion(hit) }
                return
            }
            guard !stale, let image = self.renderBlocking(spec) else { return }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Render synchronously on whatever thread calls it. Used internally from
    /// the queue, and directly by the scratchpad verification harness — a
    /// preview that draws a black rectangle or the wrong option is invisible
    /// until somebody looks at the pixels.
    @discardableResult
    func renderBlocking(_ spec: PreviewSpec) -> NSImage? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let unit = unit(for: spec) else { return nil }
        let r = unit.renderer

        r.state = spec.sceneState
        // Never on a preview: a replay would animate the thumbnail through the
        // hours it thinks it missed.
        r.playbackOnWake = false
        r.surfaces = []
        // Free when nothing changed — the renderer compares size AND row count
        // — and required when the row count did.
        r.resize(width: spec.width, height: spec.height)

        // Settle the eased heading if it moved. `sim.step` clamps dt to 0.1s, so
        // a huge step is safe there; it is only the heading filter that reads
        // the raw dt, which is precisely what needs to be jumped.
        if let last = unit.lastHeading, last != spec.facingAz {
            r.fixedTimeStep = 200
            r.render(to: unit.texture)
        }
        unit.lastHeading = spec.facingAz

        r.fixedTimeStep = 1.0 / 60.0
        // Two frames: the first settles the integrators the shader reads, the
        // second is the one we keep.
        r.render(to: unit.texture)
        r.render(to: unit.texture, waitForCompletion: true)

        guard let cg = Self.image(from: unit.texture, width: spec.width, height: spec.height)
        else { return nil }
        let img = NSImage(cgImage: cg,
                          size: NSSize(width: spec.width / 2, height: spec.height / 2))

        lock.lock()
        _stats.renders += 1
        _stats.seconds += CFAbsoluteTimeGetCurrent() - t0
        store(spec, img)
        lock.unlock()
        return img
    }

    /// Drop everything. Only for the harness; the app never needs it.
    func flushCache() {
        lock.lock(); cache.removeAll(); order.removeAll(); cachedPixels = 0; lock.unlock()
    }

    // MARK: - Internals

    /// Caller holds `lock`.
    private func store(_ spec: PreviewSpec, _ img: NSImage) {
        guard cache[spec] == nil else { return }
        cache[spec] = img
        order.append(spec)
        cachedPixels += spec.width * spec.height
        while cachedPixels > Self.pixelBudget, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
            cachedPixels -= oldest.width * oldest.height
        }
    }

    /// Queue only.
    private func unit(for spec: PreviewSpec) -> Unit? {
        let key = spec.width << 16 | spec.height
        if let u = units[key] { return u }
        if device == nil { device = MTLCreateSystemDefaultDevice() }
        guard let device,
              let renderer = ElementalRenderer(device: device, colorFormat: .rgba8Unorm)
        else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: spec.width, height: spec.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let u = Unit(renderer: renderer, texture: tex)
        units[key] = u
        return u
    }

    /// Same readback LockStill uses.
    private static func image(from tex: MTLTexture, width: Int, height: Int) -> CGImage? {
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels.withUnsafeMutableBytes { p in
            tex.getBytes(p.baseAddress!, bytesPerRow: rowBytes,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
