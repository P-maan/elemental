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

    // MARK: - Init

    init?(screen: NSScreen, config: Config, device: MTLDevice) {
        guard let num = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let r = ElementalRenderer(device: device, colorFormat: .bgra8Unorm)
        else { return nil }

        self.displayID = CGDirectDisplayID(num.uint32Value)
        self.renderer = r
        self.config = config

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
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.needsDisplayOnBoundsChange = true
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = metalLayer
        window.contentView = view

        // Sets up the furniture as well as the size and appearance — see apply.
        apply(config: config, screen: screen)
        window.orderFrontRegardless()

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
        renderer.surfaces = Furniture.desktop(screen: screen, widgets: config.widgets)
        applyFrameRate()
    }

    func updateAstro(_ astro: AstroState) {
        // A replay owns the sky while it runs; overwriting it with "now" would
        // cut the animation short.
        guard !renderer.isPlayingBack else { return }
        renderer.state.astro = astro
    }

    func updateWeather(_ w: WeatherState) {
        renderer.state.weather = w
    }

    func locationChanged() { renderer.locationChanged() }

    /// Lets the renderer work out what the sky looked like at any instant,
    /// which is what wake playback replays.
    func setAstroProvider(_ p: @escaping (Date) -> AstroState) {
        renderer.astroProvider = p
    }

    func applyFrameRate(lowPower: Bool = false) {
        let target = lowPower ? max(15, config.maxFPS / 2) : config.maxFPS
        let f = Float(target)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: max(10, f / 2),
                                                         maximum: f, preferred: f)
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
        renderer.render(to: update.drawable.texture, presenting: update.drawable)
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
