//  WallpaperSurface.swift — one live wallpaper per display.
//
//  This is the part that answers "what happens when I swipe to a fullscreen
//  app". The rule, and the reason the previous build was unpleasant:
//
//      NOTHING IS EVER TORN DOWN.
//
//  The window, the Metal layer, the textures, the pipelines and all scene state
//  are created once and live until quit. Going behind a fullscreen app pauses
//  the display link and does nothing else. Coming back sets isPaused = false.
//  There is no reload, no re-init, no blank flash and no work to redo, because
//  the scene is a function of wall-clock time rather than an accumulation of
//  frames — the first frame after waking is already the right frame.
//
//  Rebuilds happen for exactly one reason: the display's size actually changed.

import AppKit
import Metal
import QuartzCore

final class WallpaperSurface: NSObject, CAMetalDisplayLinkDelegate {

    let window: NSWindow
    let renderer: ElementalRenderer
    private let metalLayer = CAMetalLayer()
    private var link: CAMetalDisplayLink?
    private var config: Config

    /// Screen identity, so we can match surfaces to displays across
    /// reconfiguration without holding a stale NSScreen.
    let displayID: CGDirectDisplayID

    private var paused = true
    private var lastSize: CGSize = .zero
    private var lastConfig: Config?
    private weak var lastScreen: NSScreen?

    // MARK: - EDR
    //
    // Whether this surface was BUILT to carry values above white. Fixed at
    // init, because the render pipelines are compiled against the pixel format.
    let builtForHDR: Bool

    /// The largest headroom the compositor has actually granted this surface
    /// since launch. 1.0 means it has never granted any.
    private(set) var edrObserved: Float = 1

    /// Frames drawn since we started asking for EDR. Used only to decide when
    /// "not yet" has become "never" — the compositor ramps headroom over about
    /// a second, so a verdict before then would be wrong.
    private var edrFrames = 0

    /// What the toggle actually achieved, for Settings to report truthfully.
    enum EDRStatus {
        case off                 // the user has not asked for it
        case granted(Float)      // the compositor is giving us this much
        case refused             // asked, drew for seconds, never got any
        case waiting             // asked, too early to say
    }

    var edrStatus: EDRStatus {
        guard builtForHDR else { return .off }
        if edrObserved > 1.001 { return .granted(edrObserved) }
        return edrFrames > 180 ? .refused : .waiting
    }

    /// The surfaces currently on screen, weakly, keyed by display.
    ///
    /// Exists for one caller: the furniture detector, which finds the dock and
    /// the widgets by DIFFERENCING a screenshot against our own render of the
    /// same moment, and therefore has to be able to ask what that moment
    /// actually was. Nothing here may mutate a live surface.
    private static var registry: [CGDirectDisplayID: () -> WallpaperSurface?] = [:]

    static func live(display: CGDirectDisplayID) -> WallpaperSurface? {
        registry[display]?()
    }

    /// Any live surface, preferring the main display's. Settings has one pane
    /// and the user has one screenshot; this is what it was taken of.
    static var anyLive: WallpaperSurface? {
        if let main = NSScreen.main,
           let n = main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let s = live(display: CGDirectDisplayID(n.uint32Value)) { return s }
        return registry.values.compactMap { $0() }.first
    }

    // MARK: - Init

    init?(screen: NSScreen, config: Config, device: MTLDevice) {
        // Values above white only survive presentation on a float surface;
        // bgra8Unorm clamps them at 1.0. The pipelines are built for whichever
        // format is chosen here, so this is fixed for the life of the surface —
        // turning the setting on or off takes effect at the next launch.
        let wantsHDR = config.hdr
        guard let num = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let r = ElementalRenderer(device: device,
                                        colorFormat: wantsHDR ? .rgba16Float : .bgra8Unorm)
        else { return nil }

        self.displayID = CGDirectDisplayID(num.uint32Value)
        self.renderer = r
        self.config = config
        self.builtForHDR = wantsHDR

        // Borderless, non-interactive, and at the desktop window level — above
        // the system wallpaper, below the Finder's icon layer, so icons stay on
        // top. Verified on macOS 27: we land at layer -2147483623 with Finder's
        // icons at -2147483603 above us.
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.title = "Elemental Wallpaper"

        super.init()

        let view = NSView(frame: screen.frame)
        view.wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = wantsHDR ? .rgba16Float : .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        // The three things that together opt a layer into EDR: the flag, an
        // extended-range colour space, and a float pixel format above.
        //
        // Asked for, and then MEASURED — see refreshHeadroom. On every macOS
        // tested this request is refused at the desktop window level, so the
        // measurement is the part that matters.
        metalLayer.wantsExtendedDynamicRangeContent = wantsHDR
        // extendedSRGB, NOT extendedLinearSRGB. The scene is authored and
        // presented as sRGB-encoded values; the linear variant would have the
        // compositor read those same numbers as linear light and the whole
        // wallpaper would come out washed out and pale. Extended sRGB keeps the
        // sRGB transfer function for 0..1 — so everything inside the existing
        // range is presented exactly as it is today — and mirrors that curve
        // beyond 1.0, which is the part EDR uses.
        metalLayer.colorspace = CGColorSpace(name: wantsHDR
                                             ? CGColorSpace.extendedSRGB
                                             : CGColorSpace.sRGB)
        metalLayer.needsDisplayOnBoundsChange = true
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = metalLayer
        window.contentView = view

        // Sets up the furniture as well as the size and appearance — see apply.
        apply(config: config, screen: screen)
        window.orderFrontRegardless()

        let id = displayID
        Self.registry[id] = { [weak self] in self }

        let dl = CAMetalDisplayLink(metalLayer: metalLayer)
        dl.delegate = self
        dl.add(to: .main, forMode: .common)
        dl.isPaused = true
        link = dl
        applyFrameRate()

        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        link?.invalidate()
    }

    // MARK: - Configuration

    /// Resize only if the display's geometry actually changed. A no-op resize
    /// would reallocate the cell texture for nothing.
    func apply(config: Config, screen: NSScreen) {
        self.config = config
        let frame = screen.frame
        if window.frame != frame { window.setFrame(frame, display: true) }

        let scale = screen.backingScaleFactor
        let px = CGSize(width: frame.width * scale, height: frame.height * scale)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = px

        var s = renderer.state
        config.apply(to: &s)
        renderer.state = s
        renderer.motionSpeed = config.motionSpeed
        renderer.playbackOnWake = config.playbackOnWake
        renderer.playbackMaxSeconds = config.playbackMaxSeconds

        // Always call through: the renderer decides whether anything actually
        // needs rebuilding, and it now accounts for a changed row count as well
        // as a changed display size.
        lastSize = px
        // Kept so the furniture can be re-derived on a timer without a
        // config change to hang it off — see refreshFurnitureIfNeeded.
        lastConfig = config
        lastScreen = screen
        renderer.resize(width: Int(px.width), height: Int(px.height))

        // Water lands on the dock and on the desktop widgets. They draw over us,
        // so what shows is the spray thrown back into the visible area.
        //
        // Rebuilt on EVERY apply, not once in init. Widget rectangles come from
        // config, so setting them only at startup meant editing them in Settings
        // changed nothing until the app was relaunched — water kept falling
        // through a widget that had moved, and splashing off empty desktop where
        // it used to be. The dock half has the same problem: its extent depends
        // on the item count and tile size, and the screen's insets change when it
        // is hidden or moved. Recomputing is a UserDefaults read and a little
        // arithmetic, so there is no reason to cache it.
        //
        // A dock the user has corrected on the Elements grid overrides the
        // derived one — see Config.dockRect.
        renderer.surfaces = applyingDockOverride(
            Furniture.desktop(screen: screen, widgets: config.widgets),
            override: config.dockRect,
            pixelWidth: Float(px.width), pixelHeight: Float(px.height),
            enabled: config.wetDock)
        applyFrameRate()
    }

    func updateAstro(_ astro: AstroState) {
        // A replay owns the sky while it runs; overwriting it with "now" would
        // cut the animation short.
        guard !renderer.isPlayingBack else { return }
        renderer.state.astro = astro
    }

    func updateMeteorShower(_ s: (perHour: Float, alt: Float, az: Float)?) {
        renderer.meteorShower = s
    }

    func updateWeather(_ w: WeatherState) {
        renderer.state.weather = w
        // A new reading can change what the scene needs to be drawn AT.
        applyFrameRate(lowPower: lowPowerMode)
    }

    /// Re-derive the frame rate from whatever the scene is showing NOW.
    ///
    /// Separate from `applyFrameRate(lowPower:)` only so callers on a timer do
    /// not have to know the current power state.
    func refreshFrameRate() { applyFrameRate(lowPower: lowPowerMode) }

    /// Re-derive the furniture, cheaply, on a timer.
    ///
    /// Surfaces were rebuilt only when the CONFIG changed, and most of what
    /// moves them is nothing to do with the config: the dock is hidden or shown,
    /// an app is added to it or quits and leaves it, the tile size is dragged,
    /// the dock moves to another edge, the menu bar auto-hides, a display is
    /// rescaled. Until something else happened to write a setting, water went on
    /// splashing off a ledge that was no longer there and passing straight
    /// through the one that was — which is the "it gets stuck when the furniture
    /// updates" report.
    ///
    /// Deliberately a poll rather than an observer. There is no single
    /// notification that covers all of the above — `com.apple.dock` defaults
    /// changes, `NSApplication.didChangeScreenParametersNotification` and the
    /// window's own occlusion each cover part of it — and the work is a
    /// UserDefaults read plus arithmetic on a handful of rectangles. Comparing
    /// before assigning keeps it free downstream: an unchanged list does not
    /// touch the simulation, so the films and the water already on a surface are
    /// preserved rather than being reset every two seconds.
    func refreshFurnitureIfNeeded() {
        guard !paused,
              let cfg = lastConfig,
              let scr = lastScreen ?? window.screen else { return }
        let px = lastSize
        guard px.width > 0, px.height > 0 else { return }

        let derived = Furniture.desktop(screen: scr, widgets: cfg.widgets)
        let fresh = applyingDockOverride(derived,
                                         override: cfg.dockRect,
                                         pixelWidth: Float(px.width),
                                         pixelHeight: Float(px.height),
                                         enabled: cfg.wetDock)
        guard changed(renderer.surfaces, fresh) else { return }
        renderer.surfaces = fresh
    }

    /// Whether two furniture lists differ enough to be worth reassigning.
    ///
    /// Written as a plain loop rather than zip/allSatisfy: the closure form made
    /// the Swift type checker give up outright ("unable to type-check this
    /// expression in reasonable time"), which is a compile error and not a
    /// warning.
    private func changed(_ a: [Surface], _ b: [Surface]) -> Bool {
        if a.count != b.count { return true }
        for i in 0..<a.count {
            let p = a[i], q = b[i]
            if p.kind != q.kind { return true }
            if abs(p.x - q.x) > 0.5 { return true }
            if abs(p.y - q.y) > 0.5 { return true }
            if abs(p.w - q.w) > 0.5 { return true }
            if abs(p.h - q.h) > 0.5 { return true }
        }
        return false
    }

    /// Remembered so a weather-driven frame-rate update cannot silently cancel
    /// low-power mode, which is set from a different event entirely.
    private var lowPowerMode = false

    func locationChanged() { renderer.locationChanged() }

    /// Lets the renderer work out what the sky looked like at any instant,
    /// which is what wake playback replays.
    func setAstroProvider(_ p: @escaping (Date) -> AstroState) {
        renderer.astroProvider = p
    }

    func applyFrameRate(lowPower: Bool = false) {
        lowPowerMode = lowPower
        let ceiling = Float(lowPower ? max(15, config.maxFPS / 2) : config.maxFPS)

        // Ask for the rate the SCENE needs, not a constant.
        //
        // This requested `config.maxFPS` — 30 by default — every frame of every
        // hour, whatever was on screen, and that is why Elemental sits near the
        // top of the energy list. Almost nothing here moves at thirty hertz: the
        // sun and moon travel in arcs measured in hours, the deck drifts, the
        // sky colour turns over a whole twilight, the relief does not move at
        // all. A clear calm sky at thirty frames a second is the same picture
        // drawn thirty times a second.
        //
        // The things that genuinely need the rate are hydrometeors falling and
        // lightning, because both are only legible as MOTION — a rain streak
        // sampled at six hertz is a dotted line, and a flash is a single frame.
        // So the user's setting stays the CEILING and the preferred rate is
        // derived from what is actually moving. On the commonest case there is —
        // a dry sky — this asks for six instead of thirty.
        //
        // Given as a range rather than a fixed rate, so CoreAnimation can still
        // coalesce us with whatever else is driving the display; on a ProMotion
        // panel that is most of the saving, because the compositor can hold a
        // low refresh rate instead of waking to 120 for one wallpaper.
        let w = renderer.state.weather
        var need: Float = 6                        // drift, colour, breathing
        if w.precipRate > 0.02 {
            // Enough that a streak reads as a line rather than a dotted one,
            // rising with how hard it is coming down.
            need = max(need, 16 + min(14, w.precipRate * 3))
        }
        if w.isThundering { need = ceiling }       // a flash IS one frame
        if w.wind > 30 { need = max(need, 14) }    // gale-driven streak lean
        let preferred = max(4, min(ceiling, need))

        // A NARROW range when nothing is moving, a wide one when something is.
        //
        // Asking for minimum 3 / maximum 30 / preferred 6 does technically
        // average out to a cheap wallpaper, and it also lets CoreAnimation hand
        // back irregular intervals — 3 here, 30 there — which reads as stutter
        // even though the simulation integrates on real elapsed time and is
        // numerically fine. Perceived smoothness is about the REGULARITY of the
        // cadence, not its speed: a steady 6 looks calm, a 3-to-30 jitter looks
        // broken.
        //
        // So when the scene is quiet the floor is raised to the preferred rate
        // and the ceiling kept just above it, which pins a steady slow cadence.
        // When there is genuine motion — hydrometeors, lightning, a gale — the
        // ceiling opens all the way to the user's maxFPS so it can climb, which
        // is the half of this that has to stay fast.
        let moving = w.precipRate > 0.02 || w.isThundering || w.wind > 30
        let hi = moving ? ceiling : min(ceiling, preferred + 4)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: preferred,
                                                         maximum: hi,
                                                         preferred: preferred)
        renderer.state.lowFX = lowPower
    }

    // MARK: - Running
    //
    // Pause and resume are the ONLY lifecycle here. Note what these do not do:
    // they do not release the drawable, drop the textures, tear down the window
    // or reset the simulation.

    func resume() {
        guard paused else { return }
        paused = false
        link?.isPaused = false
    }

    func pause() {
        guard !paused else { return }
        paused = true
        link?.isPaused = true
        // Tell the renderer the clock is about to jump, so the next frame
        // fast-forwards the integrators instead of stepping by a huge dt.
        renderer.markIdle()
    }

    @objc private func occlusionChanged() {
        let visible = window.occlusionState.contains(.visible)
        if visible || config.renderWhenOccluded { resume() } else { pause() }
    }

    var isVisible: Bool { window.occlusionState.contains(.visible) }

    // MARK: - Frame

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        refreshHeadroom()
        renderer.render(to: update.drawable.texture, presenting: update.drawable)
    }

    /// Read the headroom the display is granting RIGHT NOW and hand it to the
    /// renderer, which passes it to the shader as `edrHead`.
    ///
    /// Every frame, not once: headroom is not a property of the panel. It moves
    /// with the brightness slider, with Low Power Mode and with thermal state,
    /// and the compositor withdraws it entirely when nothing on screen is using
    /// EDR. A wallpaper that assumed the potential headroom would simply clip.
    ///
    /// ---- The honest part.
    ///
    /// This will not rise above 1.0 for a wallpaper, and that is not a bug in
    /// this code. macOS grants EDR only to windows at or above the NORMAL
    /// window level. Measured on an M1 Pro with 16.0 of potential headroom, one
    /// CAMetalLayer with the EDR flag set and a constant 6.0 written into it:
    ///
    ///     level -2147483623 (desktop, where the wallpaper lives)  ->  1.2
    ///     level -2147483603 (Finder's desktop icons)              ->  1.2
    ///     level        -100                                       ->  1.2
    ///     level          -1                                       ->  1.2
    ///     level           0 (normal)                              -> 16.0
    ///     level        1000 (screen saver)                        -> 14.7
    ///
    /// The cutoff is exactly at level 0, and a wallpaper has to be below the
    /// icon layer to be a wallpaper at all. So the setting can do nothing here
    /// and everything in the saver. We still ask, and still measure, rather
    /// than hard-coding the refusal: if a future macOS starts granting it, this
    /// picks it up on the next frame with no change to the code.
    private func refreshHeadroom() {
        guard builtForHDR else { renderer.edrHeadroom = 1; return }
        edrFrames += 1
        let h = Float(screenForDisplay()?
            .maximumExtendedDynamicRangeColorComponentValue ?? 1)
        renderer.edrHeadroom = max(1, h)
        edrObserved = max(edrObserved, max(1, h))
    }

    private func screenForDisplay() -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber)?.uint32Value == displayID
        }
    }

    /// Render a single frame on demand, ignoring the paused state. Used by the
    /// lock-screen still exporter.
    func renderOnce(into texture: MTLTexture) {
        renderer.render(to: texture, waitForCompletion: true)
    }

    func close() {
        link?.invalidate()
        link = nil
        window.orderOut(nil)
    }
}
