//  Onboarding.swift — the first run, rendered by the engine itself.
//
//  The obvious way to onboard an app like this is a stack of cards with
//  screenshots on them. That would be a mistake here, and specifically the wrong
//  mistake: Elemental's whole claim is that it shows you the sky that is outside
//  right now, and a screenshot is a picture of somebody else's sky at some other
//  time. Onboarding that argues for the product in words, over stills, quietly
//  concedes that the product cannot argue for itself.
//
//  So this is the engine. `ElementalRenderer` drives a full-screen Metal layer
//  from the first frame, the same renderer the wallpaper and the screen saver
//  use, and the copy sits over it. Three things follow from that and they are
//  the whole design:
//
//    1. IT OPENS ON A REAL SKY. `Config.fallbackPlace()` estimates longitude
//       from the system timezone, so before a single permission is granted the
//       first frame is already a plausible sky for roughly where you are, with
//       the sun at the right height for the actual time of day. Nothing is
//       staged.
//
//    2. GRANTING LOCATION IS THE MOMENT. The scene SNAPS to the resolved
//       coordinates — `locationChanged()`, the same contract the desktop uses
//       when you change city — and the sky becomes yours while you watch. That
//       transition is the pitch. No sentence in this file works as hard.
//
//    3. EACH PERMISSION VISIBLY BUYS SOMETHING. Weather lands and the deck
//       builds; radar decides whether it is actually raining on you. The user is
//       not being asked to trust a claim, they are being shown the result.
//
//  Every step is skippable. A wallpaper that holds you hostage on step two is
//  not premium, whatever it looks like.

import AppKit
import Metal
import QuartzCore
import CoreLocation

final class OnboardingController: NSObject {

    // MARK: - Steps

    private enum Step: Int, CaseIterable {
        case welcome, location, weather, furniture, done

        var title: String {
            switch self {
            case .welcome:   return "This is the sky."
            case .location:  return "Where are you?"
            case .weather:   return "What is it doing?"
            case .furniture: return "What is in the way?"
            case .done:      return "It is running."
            }
        }

        /// One sentence. Anything longer is not read on a first run, and this
        /// scene is more persuasive than the paragraph would have been.
        var body: String {
            switch self {
            case .welcome:
                return "Not a picture of one. The sun is where it actually is, "
                     + "for this minute, drawn from your clock and the rough "
                     + "longitude of your timezone."
            case .location:
                return "Tell Elemental where you are and the sky becomes yours — "
                     + "your sun, your moon, your weather. Nothing leaves your Mac "
                     + "except the request for a forecast."
            case .weather:
                return "Cloud by altitude, measured visibility, and radar to decide "
                     + "whether it is raining on you rather than merely nearby."
            case .furniture:
                return "Rain lands on your dock and your widgets and runs off them. "
                     + "Elemental can find them from a screenshot, or you can place "
                     + "them yourself."
            case .done:
                return "Elemental lives in the menu bar. Everything here can be "
                     + "changed later, and the sky will keep up on its own."
            }
        }

        var primary: String {
            switch self {
            case .welcome:   return "Begin"
            case .location:  return "Use My Location"
            case .weather:   return "Continue"
            case .furniture: return "Place Them Now"
            case .done:      return "Done"
            }
        }

        var secondary: String? {
            switch self {
            case .welcome:   return nil
            case .location:  return "Choose a City Instead"
            case .weather:   return nil
            case .furniture: return "Not Now"
            case .done:      return "Open Settings"
            }
        }
    }

    // MARK: - State

    private var window: NSWindow!
    private var metalLayer: CAMetalLayer!
    private var renderer: ElementalRenderer!
    private var link: CVDisplayLink?
    private var timer: Timer?

    private var step: Step = .welcome
    private var state = SceneState()
    private var config: Config
    private let device: MTLDevice
    private let location: LocationService
    private let onFinish: (Config) -> Void
    private let onPlaceFurniture: () -> Void

    // Chrome
    private var titleLabel: NSTextField!
    private var bodyLabel: NSTextField!
    private var primaryButton: NSButton!
    private var secondaryButton: NSButton!
    private var statusLabel: NSTextField!
    private var pips: [NSView] = []
    private var card: NSVisualEffectView!

    private let weather = WeatherService()

    init?(config: Config, device: MTLDevice, location: LocationService,
          onPlaceFurniture: @escaping () -> Void,
          onFinish: @escaping (Config) -> Void) {
        self.config = config
        self.device = device
        self.location = location
        self.onFinish = onFinish
        self.onPlaceFurniture = onPlaceFurniture
        super.init()
        guard let r = ElementalRenderer(device: device, colorFormat: .bgra8Unorm) else { return nil }
        renderer = r
        buildWindow()
        buildChrome()
        startScene()
        show(step: .welcome, animated: false)
    }

    // MARK: - Window

    private func buildWindow() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
        // Above everything ordinary including the Dock, because this is the
        // first thing the user ever sees of Elemental and a Dock cutting across
        // it would undo the whole effect. Still below the menu bar, for the same
        // reason the placement overlay is: this is an LSUIElement app and the
        // menu bar is the only way back in.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        let host = NSView(frame: screen.frame)
        host.wantsLayer = true
        window.contentView = host

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.frame = host.bounds
        let scale = window.backingScaleFactor
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: host.bounds.width * scale,
                                    height: host.bounds.height * scale)
        host.layer?.addSublayer(layer)
        metalLayer = layer

        renderer.resize(width: Int(layer.drawableSize.width),
                        height: Int(layer.drawableSize.height))
    }

    // MARK: - Chrome
    //
    // One card, low-left, over the scene. Not centred: centring puts the copy
    // exactly where the sun or the moon is most likely to be, and the point is
    // to keep the sky readable while you read.

    private func buildChrome() {
        guard let host = window.contentView else { return }

        card = NSVisualEffectView(frame: .zero)
        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 22
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        host.addSubview(card)

        titleLabel = Self.label(size: 34, weight: .semibold, alpha: 1)
        bodyLabel = Self.label(size: 15, weight: .regular, alpha: 0.78)
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 4
        statusLabel = Self.label(size: 12, weight: .medium, alpha: 0.55)

        primaryButton = NSButton(title: "", target: self, action: #selector(primaryTapped))
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.keyEquivalent = "\r"

        secondaryButton = NSButton(title: "", target: self, action: #selector(secondaryTapped))
        secondaryButton.bezelStyle = .inline
        secondaryButton.isBordered = false
        secondaryButton.contentTintColor = .secondaryLabelColor

        for v in [titleLabel!, bodyLabel!, statusLabel!, primaryButton!, secondaryButton!] {
            card.addSubview(v)
        }

        // Progress as mosaic cells rather than dots. The grid IS the brand, and a
        // row of generic pills would be the one piece of visual language here
        // borrowed from somewhere else.
        for _ in Step.allCases {
            let pip = NSView(frame: .zero)
            pip.wantsLayer = true
            pip.layer?.cornerRadius = 2
            pip.layer?.cornerCurve = .continuous
            card.addSubview(pip)
            pips.append(pip)
        }
        layoutChrome()
    }

    private static func label(size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = NSColor.labelColor.withAlphaComponent(alpha)
        l.backgroundColor = .clear
        l.isBezeled = false
        l.isEditable = false
        return l
    }

    private func layoutChrome() {
        guard let host = window.contentView else { return }
        let w: CGFloat = 620, h: CGFloat = 300
        let x = max(64, host.bounds.width * 0.08)
        let y = max(64, host.bounds.height * 0.14)
        card.frame = NSRect(x: x, y: y, width: w, height: h)

        let pad: CGFloat = 40
        let inner = w - pad * 2
        titleLabel.frame = NSRect(x: pad, y: h - pad - 44, width: inner, height: 44)
        bodyLabel.frame = NSRect(x: pad, y: h - pad - 44 - 96, width: inner, height: 88)
        statusLabel.frame = NSRect(x: pad, y: 96, width: inner, height: 18)
        primaryButton.frame = NSRect(x: pad, y: 40, width: 210, height: 34)
        secondaryButton.frame = NSRect(x: pad + 222, y: 40, width: 220, height: 34)

        for (i, pip) in pips.enumerated() {
            pip.frame = NSRect(x: w - pad - CGFloat(pips.count - i) * 16, y: h - pad - 20,
                               width: 11, height: 11)
        }
    }

    // MARK: - The scene

    private func startScene() {
        // Seed with the best guess available before any permission: the
        // configured place if there is one, otherwise the timezone estimate.
        let p = config.scenePlace
        state.astro = Astro.update(lat: p.latitude, lon: p.longitude,
                                   facingAz: config.facingAz, date: Date())
        config.apply(to: &state)
        renderer.state = state
        renderer.astroProvider = { [weak self] date in
            guard let self else { return AstroState() }
            let p = self.config.scenePlace
            return Astro.update(lat: p.latitude, lon: p.longitude,
                                facingAz: self.config.facingAz, date: date)
        }

        weather.onUpdate = { [weak self] w in
            guard let self else { return }
            self.renderer.state.weather = w
            self.refreshStatus(w)
        }
        weather.start(at: Coordinate(latitude: p.latitude, longitude: p.longitude))

        // 30 fps is plenty and this window is short-lived; the adaptive rate
        // machinery on the wallpaper exists for something that runs for weeks.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.frame()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func frame() {
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.render(to: drawable.texture, presenting: drawable)
    }

    private func refreshStatus(_ w: WeatherState) {
        let p = config.scenePlace
        var bits = ["\(p.name)"]
        bits.append(String(format: "%.0f%% cloud", w.cover))
        if w.radarEcho >= 0 {
            bits.append(w.radarEcho > 0.05 ? "radar: rain overhead" : "radar: dry overhead")
        }
        statusLabel.stringValue = bits.joined(separator: "   ·   ")
    }

    // MARK: - Steps

    private func show(step s: Step, animated: Bool = true) {
        step = s
        titleLabel.stringValue = s.title
        bodyLabel.stringValue = s.body
        primaryButton.title = s.primary
        secondaryButton.title = s.secondary ?? ""
        secondaryButton.isHidden = s.secondary == nil

        for (i, pip) in pips.enumerated() {
            let on = i <= s.rawValue
            pip.layer?.backgroundColor = (on ? NSColor.controlAccentColor
                                             : NSColor.white.withAlphaComponent(0.18)).cgColor
        }
        guard animated else { return }
        // A short cross-fade on the copy only. The SCENE never interrupts —
        // it is the one continuous thing across the whole flow, and cutting it
        // would break the only illusion that matters.
        for v in [titleLabel!, bodyLabel!] {
            v.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                v.animator().alphaValue = 1
            }
        }
    }

    private func advance() {
        let next = Step(rawValue: step.rawValue + 1) ?? .done
        show(step: next)
    }

    @objc private func primaryTapped() {
        switch step {
        case .welcome:
            advance()

        case .location:
            // The moment. Ask, and let the resolve handler snap the scene.
            NotificationCenter.default.post(name: .elementalPermissionPrompt, object: nil)
            location.onResolve = { [weak self] place in
                guard let self else { return }
                self.config.addPlace(place)
                self.config.save()
                // Snap rather than ease: there is no transition to show between
                // a guessed place and the real one, only a first frame to get
                // right. Same contract the desktop uses on a city change.
                self.renderer.locationChanged()
                self.renderer.state.astro = Astro.update(lat: place.latitude,
                                                         lon: place.longitude,
                                                         facingAz: self.config.facingAz,
                                                         date: Date())
                self.weather.start(at: Coordinate(latitude: place.latitude,
                                                  longitude: place.longitude))
                self.statusLabel.stringValue = "Found you — \(place.name)"
                self.advance()
            }
            location.requestOnce()

        case .weather:
            advance()

        case .furniture:
            finish(openSettings: false)
            onPlaceFurniture()

        case .done:
            finish(openSettings: false)
        }
    }

    @objc private func secondaryTapped() {
        switch step {
        case .location:  finish(openSettings: true)       // pick a city by hand
        case .furniture: advance()
        case .done:      finish(openSettings: true)
        default:         advance()
        }
    }

    private func finish(openSettings: Bool) {
        config.hasOnboarded = true
        config.save()
        timer?.invalidate(); timer = nil
        weather.stop()
        window.orderOut(nil)
        onFinish(config)
        if openSettings {
            NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil)
        }
    }

    func present() {
        // Warm up BEFORE anything is visible, then fade.
        //
        // The first frames of this engine are not representative: textures are
        // allocated on the first resize, the simulation's fields start at zero
        // and fill over the first few steps, and the weather easer is walking
        // from a default state toward whatever the fetch will say. Showing that
        // is showing the machine starting up — cells popping, the deck sliding
        // into place — which is the opposite of the impression this window
        // exists to make, and it reads as jitter rather than as weather.
        //
        // So render a short warm-up into the drawable with the layer still
        // transparent, then bring it up over most of a second. By the time it is
        // visible the scene is settled and everything that moves afterwards is
        // moving because the sky is.
        metalLayer.opacity = 0
        for _ in 0..<24 { frame() }

        // A single soft note as the sky comes up.
        //
        // One note, not a sequence, and quiet: this window is trying to feel
        // like weather arriving rather than software launching, and anything
        // with a melody in it would announce the second. Submarine is the
        // softest low ping macOS ships and it decays into nothing, which is
        // roughly the shape the fade has.
        //
        // A system sound rather than a bundled asset on purpose — it costs
        // nothing, it is already tuned to the user's output device, and it
        // cannot be the wrong sample rate. If this ever gets a custom sound it
        // belongs in Resources and this is the one line that changes.
        if let chime = NSSound(named: "Submarine") {
            chime.volume = 0.22
            chime.play()
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        card.alphaValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.9
        // Ease out only: the scene arrives quickly and settles, rather than
        // creeping in from both ends, which reads as a slow app.
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        metalLayer.add(fade, forKey: "fadeIn")
        metalLayer.opacity = 1

        // The card follows the sky rather than arriving with it, so the first
        // thing you look at is the scene.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.animator().alphaValue = 1
        }
    }
}
