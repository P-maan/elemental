//  ElementalSaver.swift — Elemental.saver
//
//  The screen saver is the ONE sanctioned animated surface at the lock screen.
//  A third-party window cannot draw there (loginwindow covers every level), so
//  this is how the lock screen gets a live scene rather than a still.
//
//  Screen savers run inside legacyScreenSaver.appex, which is sandboxed, and
//  that sandbox is what killed the previous build: it hosted a WKWebView, whose
//  separate web-content process the sandbox terminates — load, die, grey
//  screen. Everything here is built to give that sandbox nothing to deny:
//
//    * no WebView, so no helper process to be killed
//    * no file reads — the shader source is compiled into this binary, and the
//      config is attempted but entirely optional
//    * no network at startup
//    * Bundle(for:) rather than Bundle.main, which inside an appex is the
//      host, not us
//    * @objc name pinned, so NSPrincipalClass resolves without Swift mangling
//
//  If anything does fail, initialisation still succeeds and we draw a plain
//  background — a wrong-looking saver is recoverable, a crashed one is a grey
//  screen with no clue why.

import ScreenSaver
import AppKit
import Metal
import QuartzCore

@objc(ElementalSaverView)
final class ElementalSaverView: ScreenSaverView {

    private var renderer: ElementalRenderer?
    private var metalLayer: CAMetalLayer?
    private var state = SceneState()
    private var lastAstro = Date.distantPast
    private var lastConfigRead = Date.distantPast
    private var failureNote: String?
    private let weather = WeatherService()

    // MARK: - Init

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 30.0
        setup()
    }

    private func setup() {
        wantsLayer = true

        guard let device = MTLCreateSystemDefaultDevice() else {
            failureNote = "no Metal device"
            NSLog("Elemental.saver: no Metal device")
            return
        }
        guard let r = ElementalRenderer(device: device, colorFormat: .bgra8Unorm) else {
            failureNote = "shader pipeline failed to build"
            NSLog("Elemental.saver: renderer init failed")
            return
        }
        renderer = r

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.frame = bounds
        layer.contentsScale = window?.backingScaleFactor ?? 2
        self.layer = layer
        metalLayer = layer

        loadConfiguration()
        // The saver resumes after long gaps more than anything else — it is
        // what comes up after a night asleep — so it wants the replay too.
        r.astroProvider = { [weak self] date in
            guard let self else { return AstroState() }
            let p = self.loadedConfig.scenePlace
            return Astro.update(lat: p.latitude, lon: p.longitude,
                                facingAz: self.loadedConfig.facingAz, date: date)
        }
        resizeIfNeeded()
        NSLog("Elemental.saver: ready (%.0fx%.0f)", bounds.width, bounds.height)
    }

    /// Load the same settings the desktop wallpaper is using, so signing out
    /// and signing back in looks like one continuous scene rather than two
    /// different ones.
    ///
    /// Order matters. The copy inside our own bundle is tried FIRST because a
    /// bundle can always read its own resources, sandbox or not — the app
    /// mirrors the live config there whenever it changes. Application Support
    /// is the fallback for when the saver is run outside the sandbox, and the
    /// built-in defaults are the last resort. Being denied everywhere costs
    /// appearance, never function.
    private func loadConfiguration() {
        var cfg = Config()
        var source = "defaults"

        if let defaults = ScreenSaverDefaults(forModuleWithName: Config.saverDomain),
           let json = defaults.string(forKey: "config"),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = decoded
            source = "ScreenSaverDefaults"
        } else if let data = try? Data(contentsOf: Config.fileURL),
                  let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = decoded
            source = "application support"
        }

        lastConfigRead = Date()
        cfg = cfg.saverConfig
        let resolved = cfg
        // Only log on a real change, or a 4-second poll floods the log.
        if resolved != loadedConfig {
            NSLog("Elemental.saver: config from %@ (place: %@, rows: %d)",
                  source, resolved.effectivePlace.name, resolved.gridRows)
        }
        resolved.apply(to: &state)
        // Grid changes need the textures rebuilding, which resize handles.
        if resolved.gridRows != loadedConfig.gridRows { renderer?.state.gridRows = resolved.gridRows }
        refreshAstro(cfg: resolved)
    }

    private var loadedConfig = Config()

    private func refreshAstro(cfg: Config? = nil) {
        let cfg = cfg ?? loadedConfig
        loadedConfig = cfg
        let p = cfg.effectivePlace
        state.astro = Astro.update(lat: p.latitude, lon: p.longitude,
                                   facingAz: cfg.facingAz, date: Date())
        lastAstro = Date()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        resizeIfNeeded()
    }

    private func resizeIfNeeded() {
        guard let layer = metalLayer, let r = renderer else { return }
        let scale = window?.backingScaleFactor ?? 2
        layer.frame = bounds
        layer.contentsScale = scale
        let px = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard px.width > 0, px.height > 0 else { return }
        layer.drawableSize = px
        r.resize(width: Int(px.width), height: Int(px.height))
        // At the lock screen the clock and login field are drawn over us by
        // loginwindow, so water splashes around them the same way it does off
        // the dock on the desktop.
        r.surfaces = Furniture.lockScreen(width: Float(px.width), height: Float(px.height),
                                          includeLoginBox: !isPreview)
    }

    // MARK: - Animation

    override func startAnimation() {
        super.startAnimation()
        // The saver runs in its own process and cannot rely on the app being
        // alive, so it fetches its own conditions.
        weather.onUpdate = { [weak self] w in self?.state.weather = w }
        let p = loadedConfig.scenePlace
        weather.start(at: Coordinate(latitude: p.latitude, longitude: p.longitude))
        refreshAstro()
        renderer?.markIdle()
    }

    override func stopAnimation() {
        super.stopAnimation()
        weather.stop()
        renderer?.markIdle()
    }

    override func animateOneFrame() {
        guard let r = renderer, let layer = metalLayer else { return }

        // Settings can change while the saver is running, and it used to read
        // config only once at startup — so the saver drifted from the desktop
        // permanently. Cheap enough to re-read every few seconds.
        if Date().timeIntervalSince(lastConfigRead) > 4 { loadConfiguration() }
        if Date().timeIntervalSince(lastAstro) > 60 && !r.isPlayingBack { refreshAstro() }

        // Assign the WHOLE state, then put back the two things the renderer owns
        // rather than us. Copying field by field is what caused this bug and the
        // lock-screen one before it: a hand-maintained list silently omits every
        // field added later — glassAmplify and lowFX were both missing here.
        let astro = r.isPlayingBack ? r.state.astro : state.astro
        r.state = state
        r.state.astro = astro

        r.playbackOnWake = loadedConfig.playbackOnWake
        r.playbackMaxSeconds = loadedConfig.playbackMaxSeconds
        r.motionSpeed = loadedConfig.motionSpeed

        guard let drawable = layer.nextDrawable() else { return }
        r.render(to: drawable.texture, presenting: drawable)
    }

    /// Only used if the renderer never came up — better a readable background
    /// than a grey screen with nothing to go on.
    override func draw(_ rect: NSRect) {
        guard renderer == nil else { return }
        NSColor.black.setFill()
        rect.fill()
        guard let note = failureNote else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let s = "Elemental: \(note)" as NSString
        s.draw(at: NSPoint(x: 24, y: 24), withAttributes: attrs)
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
