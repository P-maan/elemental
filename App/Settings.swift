//  Settings.swift — the control surface.
//
//  A sidebar-style preferences window, the shape modern System Settings uses:
//  an NSSplitViewController with a source list on the left and one pane on the
//  right. AppKit has no built-in sidebar tab style — NSTabViewController only
//  offers toolbar and segmented — so the split view is the way to get it.
//
//  The three surfaces Elemental draws (desktop, lock screen, screen saver) get
//  a pane each, and they share one class rather than three copies of the same
//  controls; `role` is the only thing that differs.
//
//  Reachable two ways, so hiding the menu-bar item never locks you out: the
//  menu-bar item, or launching Elemental again from Spotlight or Finder (see
//  applicationShouldHandleReopen in main.swift).
//
//  ---- What this window is trying to be
//
//  It had grown a lot of advanced controls, and the complaint was exact:
//  somebody who does not want something this advanced cannot tell what any of
//  it does. "Splay", "Emphasis" and "Dispersion" are not words, they are shader
//  parameters, and a paragraph of prose under a slider is a worse answer than a
//  picture. So the window is now built around SEEING:
//
//    * every pane opens with a HERO — a large live render of the scene exactly
//      as configured, which updates while you drag.
//    * every relief and glass slider carries a none/half/full strip. Click a
//      tile to jump there.
//    * shape and finish are four thumbnails you pick from, not a dropdown of
//      two nouns and two other nouns.
//    * grid density is shown at five densities rather than described as a
//      number of rows.
//
//  Layout vocabulary — cards, hero, type scale, materials — lives in
//  SettingsKit.swift. Thumbnail rendering lives in PreviewRenderer.swift.
//
//  ---- The performance rule
//
//  Settings had a bad lag problem, fixed by splitting cheap live updates from
//  expensive work debounced by ~0.45s, and nothing here may undo that. The
//  worst bug this project has had was the lock-still exporter doing a render
//  and a PNG encode on the animation's runloop, freezing the wallpaper for
//  337ms a minute; a window full of live thumbnails is exactly the shape that
//  could bring it back. It does not, because every render goes through
//  `ScenePreview`: one shared renderer per pixel size, small targets, cached by
//  the parameters that produced the image, superseded requests dropped before
//  they reach the GPU, and all of it on a background queue that hands back
//  nothing but a finished NSImage.
//
//  Measured, on an M1 Pro: 0.73ms a strip tile, 0.80ms an option tile, 2.36ms a
//  hero, plus one 550ms shader compile the first time a preview is asked for.
//  A 120-event drag of one slider — hero live, seven strips behind a 0.35s
//  debounce — costs 1.2ms of MAIN THREAD time in total (0.009ms per event) and
//  138 renders, 2502 of the 2640 requests having been dropped as superseded
//  before reaching the GPU.

import AppKit
import ServiceManagement
import MapKit

// MARK: - Shared form building

class Pane: NSViewController {

    /// The column of cards.
    let stack = NSStackView()
    weak var owner: SettingsWindowController?

    /// Sidebar presentation.
    var title_: String { "" }
    var symbol: String { "gearshape" }

    override func loadView() {
        stack.orientation = .vertical
        // Cards are stretched to the pane width by `addCard`, one explicit
        // constraint each, rather than by a `.width` stack alignment — that
        // alignment produced a pane whose cards all landed on top of one
        // another, with no constraint warning to say so.
        stack.alignment = .leading
        stack.spacing = UI.cardGap
        stack.edgeInsets = NSEdgeInsets(top: UI.paneInset, left: UI.paneInset,
                                        bottom: UI.paneInset + 8, right: UI.paneInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true

        // Material behind the pane. This one change is most of what makes the
        // window read as a Mac window rather than as an AppKit form.
        let backdrop = NSVisualEffectView()
        backdrop.material = .contentBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: backdrop.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        view = backdrop
        build()
    }

    /// Subclasses populate `stack` here, through `addCard`.
    func build() {}

    /// Add a full-width item to the pane's column.
    ///
    /// The width is constrained explicitly against the stack rather than left
    /// to the stack's alignment, so every card ends up the same width and the
    /// column has one clean edge.
    func addCard(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                 constant: -2 * UI.paneInset).isActive = true
    }

    /// Called whenever the config changes underneath the pane.
    ///
    /// Only ever call this through `syncSafely` — NSViewController loads its
    /// view lazily, so a pane the user has not visited yet has run neither
    /// `loadView` nor `build`, and every control is still nil.
    func sync(_ config: Config) {}

    /// Force the view (and therefore `build`) before syncing.
    func syncSafely(_ config: Config) {
        loadViewIfNeeded()
        sync(config)
    }

    // ---- previews
    //
    // Every pane is built and synced eagerly — `syncSafely` forces `loadView`
    // on all of them — but only one is ever in the window. Rendering thumbnails
    // for panes nobody is looking at would be pure cost, so preview work is
    // gated on the pane actually being on screen and caught up when it appears.

    var isPaneVisible: Bool { isViewLoaded && view.window != nil }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshPreviews()
    }

    /// The hero, if this pane has one. Cheap to update: one coalesced request.
    func updateLivePreview(_ config: Config) {
        guard let hero, let spec = heroSpec(config) else { return }
        hero.show(spec)
    }

    /// The strips and option tiles — a dozen or more renders, so this is
    /// debounced rather than run on every mouse move.
    func updateRangePreviews(_ config: Config) {
        for r in reliefStrips {
            guard var base = heroSpec(config) else { return }
            base.width = Int(ScenePreview.small.width)
            base.height = Int(ScenePreview.small.height)
            base.nightMoon = r.night
            r.strip.show(base) { s, v in s[keyPath: r.key] = PreviewSpec.pct(v) }
            r.strip.mark(current: r.slider.value, tolerance: 0.03)
        }
    }

    /// Everything, at once. For appearing on screen — when a pane is first
    /// shown there is nothing to coalesce with and the user is waiting.
    func refreshPreviews() {
        guard isPaneVisible, let c = owner?.config else { return }
        updateLivePreview(c)
        updateRangePreviews(c)
    }

    /// Everything, but with the expensive half deferred. This is what a value
    /// CHANGE uses.
    ///
    /// `sync` runs on every commit from anywhere, and calling `refreshPreviews`
    /// from it was measurably wrong: a 120-event drag issued 2640 requests and
    /// pushed 997 of them all the way to the GPU, because the undebounced path
    /// re-rendered all 21 strip tiles on every single mouse move. Through here
    /// the same drag costs 121.
    func refreshPreviewsDebounced() {
        guard isPaneVisible, let c = owner?.config else { return }
        updateLivePreview(c)
        scheduleRangePreviews()
    }

    /// Coalesce the expensive half while a control is being worked. Mirrors the
    /// 0.45s settle in AppDelegate.applyConfig, for the same reason.
    private var rangeTimer: Timer?

    func scheduleRangePreviews() {
        rangeTimer?.invalidate()
        rangeTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) {
            [weak self] _ in
            self?.rangeTimer = nil
            guard let self, self.isPaneVisible, let c = self.owner?.config else { return }
            self.updateRangePreviews(c)
        }
    }

    // ---- hero

    private(set) var hero: HeroPreview?

    /// The scene this pane's previews should draw. Subclasses override.
    func heroSpec(_ config: Config) -> PreviewSpec? { nil }

    /// Put a hero at the top of the pane, centred, over its caption.
    func installHero(_ caption: String) {
        let h = HeroPreview()
        hero = h
        let cap = captionLabel(caption, width: HeroPreview.points.width)
        cap.alignment = .center
        let col = NSStackView(views: [h, cap])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 8
        col.translatesAutoresizingMaskIntoConstraints = false
        // Centred in the pane whatever the window width, without stretching the
        // render — see ScenePreview.large.
        addCard(centred(col))
    }

    // ---- relief strips

    /// A relief slider, its none/half/full strip, and the preview field it
    /// varies. Held together so a strip cannot drift out of step with its
    /// slider — the failure mode that makes a picture worse than no picture.
    struct ReliefStrip {
        let slider: LabelledSlider
        let strip: PreviewStrip
        let key: WritableKeyPath<PreviewSpec, Int>
        let night: Bool
    }
    private(set) var reliefStrips: [ReliefStrip] = []

    /// A slider row that shows what the slider does.
    ///
    /// The row itself on top, and under it three thumbnails of this setting at
    /// none, half and full — click one to jump straight to that value. `key` is
    /// the `PreviewSpec` field the strip varies, which is what lets one helper
    /// serve all seven controls without any of them being wired by hand.
    func reliefRow(_ title: String, _ s: LabelledSlider,
                   _ key: WritableKeyPath<PreviewSpec, Int>,
                   night: Bool = false) -> NSView {
        let strip = PreviewStrip(points: NSSize(width: 66, height: 42),
                                 entries: [(value: 0.0, caption: "none"),
                                           (value: 0.5, caption: "half"),
                                           (value: 1.0, caption: "full")],
                                 spacing: 6)
        strip.onPick = { [weak s] v in
            guard let s else { return }
            s.value = v
            s.refresh()
            // Exactly the path a drag takes, so clicking a tile and dragging to
            // the same place cannot produce different results.
            s.slider.sendAction(s.slider.action, to: s.slider.target)
        }
        reliefStrips.append(ReliefStrip(slider: s, strip: strip, key: key, night: night))

        // The strip lines up under the control, not under the label.
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: UI.labelWidth + 10).isActive = true
        let stripRow = NSStackView(views: [indent, strip])
        stripRow.spacing = 0
        stripRow.alignment = .top

        let col = NSStackView(views: [formRow(title, s.box), stripRow])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false
        return col
    }

    // ---- small builders

    func note(_ t: String) -> NSTextField { captionLabel(t) }

    func row(_ title: String, _ control: NSView) -> NSView { formRow(title, control) }

    func popup(_ titles: [String], _ action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: titles)
        p.target = self; p.action = action
        p.font = UI.body
        return p
    }

    func check(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.font = UI.body
        return b
    }

    func slider(_ title: String, _ range: ClosedRange<Double>,
                _ action: Selector, _ format: @escaping (Double) -> String) -> LabelledSlider {
        let ls = LabelledSlider(range: range, format: format)
        ls.slider.target = self; ls.slider.action = action
        ls.container = formRow(title, ls.box)
        return ls
    }
}

/// Slider plus its read-out. `value` keeps the two in step in both directions.
final class LabelledSlider {
    let slider = NSSlider()
    let label = NSTextField(labelWithString: "")
    let box = NSStackView()
    /// The full row, for showing and hiding.
    var container: NSView!
    private let format: (Double) -> String

    init(range: ClosedRange<Double>, format: @escaping (Double) -> String) {
        self.format = format
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        label.font = UI.value
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 40).isActive = true
        box.setViews([slider, label], in: .leading)
        box.spacing = 8
        box.alignment = .centerY
    }

    /// Rounded to two decimals so the stored config does not accumulate the
    /// slider's float noise.
    var value: Double {
        get { (slider.doubleValue * 100).rounded() / 100 }
        set { slider.doubleValue = newValue; label.stringValue = format(newValue) }
    }

    func refresh() { label.stringValue = format(value) }
}

// MARK: - General

final class GeneralPane: Pane {

    override var title_: String { "General" }
    override var symbol: String { "gearshape" }

    private var loginCheck: NSButton!
    private var fpsPop: NSPopUpButton!
    private var speedPop: NSPopUpButton!
    private var replayPop: NSPopUpButton!
    private var occludedCheck: NSButton!
    private var lowPowerCheck: NSButton!
    private var lockSyncCheck: NSButton!

    private var depthS: LabelledSlider!
    private var emphS: LabelledSlider!
    private var lightS: LabelledSlider!
    private var refractS: LabelledSlider!
    private var dispersS: LabelledSlider!
    private var frostS: LabelledSlider!
    private var splayS: LabelledSlider!
    /// The whole glass card. These three describe light passing THROUGH a
    /// block; a flat tile is opaque, so on flat the card goes away rather than
    /// sitting there doing nothing. A dead control is worse than a missing one.
    private var glassCard: Card!

    static let fpsChoices = [10, 15, 30, 60, 120]
    static let speedChoices: [(String, Double)] = [
        ("Glacial — 0.15×", 0.15), ("Very slow — 0.3×", 0.3), ("Slow — 0.6×", 0.6),
        ("Real time", 1.0), ("Brisk — 1.5×", 1.5),
    ]
    static let replayChoices: [(String, Double)] = [
        ("Off", 0), ("Flick — 2s", 2), ("Normal — 5s", 5), ("Slow — 10s", 10), ("Cinematic — 20s", 20),
    ]

    override func heroSpec(_ c: Config) -> PreviewSpec? {
        PreviewSpec.desktop(c, pixels: ScenePreview.large)
    }

    override func build() {
        installHero("Your mosaic, drawn with the settings below, on a sample afternoon "
                  + "over your city. It updates as you drag.")

        let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

        // ---- relief
        depthS = slider("Depth", 0...1, #selector(changed), pct)
        emphS = slider("Emphasis", 0...1, #selector(changed), pct)
        lightS = slider("Light", 0...1, #selector(changed), pct)
        splayS = slider("Splay", 0...1, #selector(changed), pct)

        let relief = Card("Relief", symbol: "cube")
        relief.add(captionLabel("Every cell is a block pushed out of the wall by its own brightness, so "
                              + "the clouds and the moon emboss the mosaic instead of only colouring it."))
        relief.add(reliefRow("Depth", depthS, \.depth))
        relief.add(reliefRow("Emphasis", emphS, \.emphasis))
        relief.add(reliefRow("Light", lightS, \.light))
        relief.add(reliefRow("Splay", splayS, \.splay))
        relief.note("Depth is how far the blocks stand out. Emphasis decides whether they follow "
                  + "features or plain tone. Light shades their side faces and the crevices between "
                  + "them. Splay unsettles the courses so the wall is not perfectly regular.")
        addCard(relief)

        // ---- glass
        refractS = slider("Refraction", 0...1, #selector(changed), pct)
        dispersS = slider("Dispersion", 0...1, #selector(changed), pct)
        frostS = slider("Frost", 0...1, #selector(changed), pct)

        glassCard = Card("Glass", symbol: "drop")
        glassCard.add(captionLabel("Only for a glass finish — a flat tile is opaque and has nothing to "
                                 + "transmit. Previewed against a full moon, which is where glass shows."))
        glassCard.add(reliefRow("Refraction", refractS, \.refraction, night: true))
        glassCard.add(reliefRow("Dispersion", dispersS, \.dispersion, night: true))
        glassCard.add(reliefRow("Frost", frostS, \.frost, night: true))
        glassCard.note("Refraction is how far you see through each block, so what lands on its face is "
                     + "the wall a little way behind — the further from the centre of the screen, the "
                     + "further off. Dispersion splits that per colour and fringes the edges; frost "
                     + "scatters it. These are subtle by nature: look at the hero above, not the strips.")
        addCard(glassCard)

        // ---- startup
        loginCheck = check("Open Elemental at login", #selector(loginToggled))
        let startup = Card("Startup", symbol: "power")
        startup.add(loginCheck)
        startup.note("Elemental has no Dock icon. Launching it again from Spotlight or Finder reopens "
                   + "these settings.")
        addCard(startup)

        // ---- motion
        fpsPop = popup(Self.fpsChoices.map { "\($0) fps" }, #selector(changed))
        speedPop = popup(Self.speedChoices.map(\.0), #selector(changed))
        replayPop = popup(Self.replayChoices.map(\.0), #selector(changed))
        let motion = Card("Motion", symbol: "waveform")
        motion.add(row("Frame rate", fpsPop))
        motion.add(row("Speed", speedPop))
        motion.note("Frame rate is how often it is drawn; speed is how fast the world runs. Lowering "
                  + "the frame rate saves power; slowing the motion costs nothing and reads calmer.")
        motion.rule()
        motion.add(row("Wake replay", replayPop))
        motion.note("After sleep or a closed lid, the scene replays the hours it missed as a time-lapse "
                  + "before settling into now. Gaps under ten minutes always resume instantly.")
        addCard(motion)

        // ---- power
        occludedCheck = check("Keep drawing when fully covered", #selector(changed))
        lowPowerCheck = check("Reduce detail and frame rate in Low Power Mode", #selector(changed))
        let power = Card("Power", symbol: "battery.100")
        power.add(occludedCheck)
        power.add(lowPowerCheck)
        power.note("Behind a fullscreen app Elemental pauses but is never unloaded, so coming back is a "
                 + "single frame with no reload.")
        addCard(power)

        // ---- lock
        lockSyncCheck = check("Show the scene on the lock screen", #selector(changed))
        let lock = Card("Lock screen", symbol: "lock.display")
        lock.add(lockSyncCheck)
        lock.note("Replaces your desktop picture with a still of the scene, refreshed every minute and "
                + "again the moment you lock. macOS does not permit animation behind the password "
                + "field — the screen saver is the only animated surface at the lock.")
        addCard(lock)
    }

    override func sync(_ c: Config) {
        loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        fpsPop.selectItem(at: Self.fpsChoices.firstIndex(of: c.maxFPS) ?? 2)
        speedPop.selectItem(at: Self.speedChoices.firstIndex { abs($0.1 - c.motionSpeed) < 0.001 } ?? 3)
        replayPop.selectItem(at: c.playbackOnWake
            ? (Self.replayChoices.firstIndex { abs($0.1 - c.playbackMaxSeconds) < 0.001 } ?? 2) : 0)
        occludedCheck.state = c.renderWhenOccluded ? .on : .off
        lowPowerCheck.state = c.lowPowerOnBattery ? .on : .off
        lockSyncCheck.state = c.syncLockScreen ? .on : .off
        depthS.value = c.reliefDepth
        emphS.value = c.emphasis
        lightS.value = c.lightIntensity
        splayS.value = c.splay
        refractS.value = c.refraction
        dispersS.value = c.dispersion
        frostS.value = c.frost
        // The desktop's finish decides it: the lock screen and saver can differ,
        // but this is one shared wall and the pane it lives on is the general one.
        UI.setHidden([glassCard], c.finish != .glass)
        refreshPreviewsDebounced()
    }

    @objc private func loginToggled() {
        do {
            if loginCheck.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert()
            a.messageText = "Could not change the login item"
            a.informativeText = "\(error.localizedDescription)\n\nYou can also set this in "
                              + "System Settings › General › Login Items."
            a.runModal()
            loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    @objc private func changed() {
        guard var c = owner?.config else { return }
        c.maxFPS = Self.fpsChoices[max(0, min(Self.fpsChoices.count - 1, fpsPop.indexOfSelectedItem))]
        c.motionSpeed = Self.speedChoices[max(0, min(Self.speedChoices.count - 1, speedPop.indexOfSelectedItem))].1
        let rp = Self.replayChoices[max(0, min(Self.replayChoices.count - 1, replayPop.indexOfSelectedItem))]
        c.playbackOnWake = rp.1 > 0
        if rp.1 > 0 { c.playbackMaxSeconds = rp.1 }
        c.renderWhenOccluded = occludedCheck.state == .on
        c.lowPowerOnBattery = lowPowerCheck.state == .on
        c.syncLockScreen = lockSyncCheck.state == .on
        c.reliefDepth = depthS.value
        c.emphasis = emphS.value
        c.lightIntensity = lightS.value
        c.splay = splayS.value
        c.refraction = refractS.value
        c.dispersion = dispersS.value
        c.frost = frostS.value
        for s in [depthS, emphS, lightS, splayS, refractS, dispersS, frostS] { s?.refresh() }
        // Cheap now, expensive later — the split that keeps the window smooth.
        updateLivePreview(c)
        scheduleRangePreviews()
        owner?.commit(c, from: self)
    }
}

// MARK: - A surface's appearance
//
// One class, three instances. `role` decides whether it offers the mimic
// checkbox at all — the desktop is the thing being mimicked, so it does not.

final class SurfacePane: Pane {

    enum Role { case desktop, lock, saver }

    private let role: Role
    private let blurb: String
    private let paneTitle: String
    private let paneSymbol: String

    override var title_: String { paneTitle }
    override var symbol: String { paneSymbol }

    private var mirrorCheck: NSButton!
    private var rowsField: NSTextField!
    private var rowsStepper: NSStepper!
    private var headingPop: NSPopUpButton!
    private var facingSlider: NSSlider!
    private var facingLabel: NSTextField!
    private var facingRow: NSView!
    private var placePop: NSPopUpButton!
    private var bodyViews: [NSView] = []
    private var places: [Place] = []

    /// The four shape-and-finish combinations, as pictures.
    private var styleChoices: [PreviewChoice] = []
    private static let styleCombos: [(MosaicShape, MosaicFinish, String)] = [
        (.square, .glass, "Square · Glass"),
        (.square, .flat,  "Square · Flat"),
        (.dot,    .glass, "Dot · Glass"),
        (.dot,    .flat,  "Dot · Flat"),
    ]
    private var pickedShape: MosaicShape = .square
    private var pickedFinish: MosaicFinish = .glass

    /// Grid density, also as pictures.
    private var densityStrip: PreviewStrip!
    private static let densities: [Double] = [14, 24, 36, 56, 84]

    init(role: Role, title: String, symbol: String, blurb: String) {
        self.role = role
        self.paneTitle = title
        self.paneSymbol = symbol
        self.blurb = blurb
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func heroSpec(_ c: Config) -> PreviewSpec? {
        PreviewSpec.surface(c, style(from: c), pixels: ScenePreview.large)
    }

    override func build() {
        installHero(blurb)

        if role != .desktop {
            mirrorCheck = check("Mimic Home Screen settings", #selector(mirrorToggled))
            let m = Card()
            m.add(mirrorCheck)
            addCard(m)
        }

        // ---- shape and finish, as four thumbnails
        let styleRow = NSStackView()
        styleRow.orientation = .horizontal
        styleRow.alignment = .top
        styleRow.spacing = 8
        styleRow.translatesAutoresizingMaskIntoConstraints = false
        for (i, combo) in Self.styleCombos.enumerated() {
            let c = PreviewChoice(points: NSSize(width: 108, height: 68), caption: combo.2)
            c.onSelect = { [weak self] in self?.pickStyle(i) }
            styleChoices.append(c)
            styleRow.addArrangedSubview(c)
        }

        rowsField = NSTextField()
        rowsField.formatter = { let f = NumberFormatter(); f.allowsFloats = false
                                f.minimum = 12; f.maximum = 120; return f }()
        rowsField.font = UI.body
        rowsField.widthAnchor.constraint(equalToConstant: 54).isActive = true
        rowsField.target = self; rowsField.action = #selector(rowsTyped)
        rowsStepper = NSStepper()
        rowsStepper.minValue = 12; rowsStepper.maxValue = 120; rowsStepper.increment = 1
        rowsStepper.target = self; rowsStepper.action = #selector(stepperChanged)
        let rowsBox = NSStackView(views: [rowsField, rowsStepper])
        rowsBox.spacing = 4
        rowsBox.alignment = .centerY

        densityStrip = PreviewStrip(points: NSSize(width: 96, height: 60),
                                    entries: Self.densities.map {
                                        (value: $0, caption: "\(Int($0)) rows")
                                    },
                                    spacing: 8)
        densityStrip.onPick = { [weak self] v in
            guard let self else { return }
            self.rowsField.integerValue = Int(v)
            self.rowsStepper.integerValue = Int(v)
            self.write(self.collect())
        }

        let mosaic = Card("Mosaic", symbol: "square.grid.3x3")
        mosaic.add(captionLabel("The shape of a cell and whether it is glass or flat. Pick the one that "
                              + "looks right — the four are shown exactly as they will draw."))
        mosaic.add(styleRow)
        mosaic.rule()
        mosaic.add(captionLabel("Density — how many cells fit down the screen."))
        mosaic.add(densityStrip)
        mosaic.add(row("Rows", rowsBox))
        mosaic.note("Cells down the screen. The Pi uses 36; more rows is a finer grid.")

        // ---- sky
        headingPop = popup(HeadingMode.allCases.map(\.title), #selector(changed))
        facingSlider = NSSlider()
        facingSlider.minValue = 0; facingSlider.maxValue = 359
        facingSlider.controlSize = .small
        facingSlider.target = self; facingSlider.action = #selector(changed)
        facingSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        facingLabel = NSTextField(labelWithString: "")
        facingLabel.font = UI.value
        facingLabel.textColor = .secondaryLabelColor
        let facingBox = NSStackView(views: [facingSlider, facingLabel])
        facingBox.spacing = 8
        facingBox.alignment = .centerY
        facingRow = row("Facing", facingBox)
        placePop = popup([], #selector(changed))

        let sky = Card("Sky", symbol: "sun.and.horizon")
        sky.add(row("Heading", headingPop))
        sky.add(facingRow)
        sky.note("Custom looks one way and lets the sky drift past. Dynamic follows whatever is up — "
               + "the sun by day, the moon once it has risen — panning between them at dusk.")
        sky.rule()
        sky.add(row("Show sky over", placePop))

        bodyViews = [mosaic, sky]
        bodyViews.forEach { addCard($0) }
    }

    private func style(from c: Config) -> Config.SurfaceStyle {
        switch role {
        case .desktop:
            return Config.SurfaceStyle(mirrorsDesktop: false, shape: c.shape, finish: c.finish,
                                       gridRows: c.gridRows, poster: c.poster,
                                       headingMode: c.headingMode, facingAz: c.facingAz,
                                       scenePlaceName: c.scenePlaceName)
        case .lock:  return c.lock
        case .saver: return c.saver
        }
    }

    override func sync(_ c: Config) {
        let st = style(from: c)
        places = c.allPlaces
        mirrorCheck?.state = st.mirrorsDesktop ? .on : .off
        pickedShape = st.shape
        pickedFinish = st.finish
        for (i, combo) in Self.styleCombos.enumerated() {
            styleChoices[i].isSelected = (combo.0 == st.shape && combo.1 == st.finish)
        }
        rowsField.integerValue = st.gridRows
        rowsStepper.integerValue = st.gridRows
        headingPop.selectItem(at: Int(st.headingMode.rawValue))
        facingSlider.doubleValue = st.facingAz
        facingLabel.stringValue = Self.bearing(st.facingAz)

        placePop.removeAllItems()
        if places.isEmpty {
            placePop.addItem(withTitle: c.effectivePlace.name); placePop.isEnabled = false
        } else {
            placePop.isEnabled = true
            placePop.addItems(withTitles: places.map(\.name))
            let want = st.scenePlaceName ?? c.scenePlace.name
            if let i = places.firstIndex(where: { $0.name == want }) { placePop.selectItem(at: i) }
        }
        applyVisibility(st)
        refreshPreviewsDebounced()
    }

    /// The option tiles, which are this pane's expensive previews.
    override func updateRangePreviews(_ c: Config) {
        super.updateRangePreviews(c)
        guard let base0 = heroSpec(c) else { return }
        var base = base0
        base.width = Int(ScenePreview.medium.width)
        base.height = Int(ScenePreview.medium.height)
        for (i, combo) in Self.styleCombos.enumerated() {
            var s = base
            s.shape = combo.0; s.finish = combo.1
            styleChoices[i].show(s)
        }
        densityStrip.show(base) { s, v in s.gridRows = Int(v) }
        densityStrip.mark(current: Double(base.gridRows), tolerance: 0.5)
    }

    private func applyVisibility(_ st: Config.SurfaceStyle) {
        let hidden = (role != .desktop) && st.mirrorsDesktop
        UI.setHidden(bodyViews, hidden)
        if let h = hero { UI.setHidden([h], false) }
        if !hidden { UI.setHidden([facingRow], st.headingMode != .custom) }
    }

    private func collect() -> Config.SurfaceStyle {
        var st = owner.map { style(from: $0.config) } ?? Config.SurfaceStyle()
        st.mirrorsDesktop = (role != .desktop) && (mirrorCheck?.state == .on)
        st.shape = pickedShape
        st.finish = pickedFinish
        st.gridRows = max(12, min(120, rowsField.integerValue))
        st.headingMode = HeadingMode(rawValue: Int32(headingPop.indexOfSelectedItem)) ?? .custom
        st.facingAz = facingSlider.doubleValue.rounded()
        let i = placePop.indexOfSelectedItem
        st.scenePlaceName = (i >= 0 && i < places.count) ? places[i].name : nil
        return st
    }

    private func write(_ st: Config.SurfaceStyle) {
        guard var c = owner?.config else { return }
        switch role {
        case .desktop:
            c.shape = st.shape; c.finish = st.finish; c.gridRows = st.gridRows
            c.poster = st.poster; c.headingMode = st.headingMode
            c.facingAz = st.facingAz; c.scenePlaceName = st.scenePlaceName
        case .lock:  c.lock = st
        case .saver: c.saver = st
        }
        updateLivePreview(c)
        scheduleRangePreviews()
        owner?.commit(c, from: self)
    }

    private func pickStyle(_ i: Int) {
        guard i >= 0, i < Self.styleCombos.count else { return }
        pickedShape = Self.styleCombos[i].0
        pickedFinish = Self.styleCombos[i].1
        for (j, c) in styleChoices.enumerated() { c.isSelected = (j == i) }
        write(collect())
    }

    @objc private func mirrorToggled() {
        var st = collect()
        st.mirrorsDesktop = mirrorCheck.state == .on
        applyVisibility(st)
        write(st)
    }

    @objc private func changed() {
        let st = collect()
        facingLabel.stringValue = Self.bearing(st.facingAz)
        UI.setHidden([facingRow], st.headingMode != .custom)
        write(st)
    }

    @objc private func stepperChanged() {
        rowsField.integerValue = rowsStepper.integerValue
        write(collect())
    }

    @objc private func rowsTyped() {
        let v = max(12, min(120, rowsField.integerValue))
        rowsField.integerValue = v
        rowsStepper.integerValue = v
        write(collect())
    }

    static func bearing(_ deg: Double) -> String {
        let names = ["N","NE","E","SE","S","SW","W","NW"]
        return String(format: "%3d°  %@", Int(deg), names[Int((deg / 45).rounded()) % 8])
    }
}

// MARK: - Weather on the desktop
//
// The wallpaper draws BEHIND the dock, the widgets and the menu bar, so weather
// that lands on one of them shows in the space around it. Which of them you
// want marked is a matter of taste and of what your desktop actually looks like
// — a hidden dock has no lip to wet — so each is opt-out on its own. Until now
// there was no UI for any of it.
//
// The picture here is a drawn schematic rather than a render: see the note on
// FurnitureDiagram for why a thumbnail cannot answer this question and why
// borrowing the global the engine reads would disturb the live wallpaper.

final class WaterPane: Pane {

    override var title_: String { "Weather" }
    override var symbol: String { "cloud.rain" }

    private var diagram: FurnitureDiagram!
    private var dockCheck: NSButton!
    private var widgetsCheck: NSButton!
    private var menuBarCheck: NSButton!
    private var furnitureS: LabelledSlider!
    private var paneCheck: NSButton!
    private var paneS: LabelledSlider!
    private var furnitureRows: [NSView] = []
    private var paneRows: [NSView] = []

    override func build() {
        diagram = FurnitureDiagram()
        let cap = captionLabel("Highlighted parts of your screen are the ones weather is allowed to mark.",
                               width: 240)
        cap.alignment = .center
        let col = NSStackView(views: [diagram, cap])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 8
        col.translatesAutoresizingMaskIntoConstraints = false
        addCard(centred(col))

        let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

        dockCheck = check("Dock", #selector(changed))
        widgetsCheck = check("Desktop widgets", #selector(changed))
        menuBarCheck = check("Menu bar", #selector(changed))
        furnitureS = slider("Strength", 0...1, #selector(changed), pct)
        furnitureRows = [furnitureS.container]

        let furniture = Card("Weather on your desktop furniture", symbol: "macwindow")
        furniture.add(captionLabel("Rain, spray and snow can gather around the edges of the things on "
                                 + "your screen — a wet band along the lip of the dock, snow lying on "
                                 + "a widget, frost blooming out from the menu bar."))
        furniture.add(dockCheck)
        furniture.add(widgetsCheck)
        furniture.add(menuBarCheck)
        furniture.add(furnitureS.container)
        furniture.note("The menu bar is off by default: it is the one strip that is always there "
                     + "whatever you are doing, and water on it reads as a UI glitch rather than as "
                     + "weather. Strength dials the whole effect back without turning it off.")
        addCard(furniture)

        paneCheck = check("Water on the screen itself", #selector(changed))
        paneS = slider("Strength", 0...1, #selector(changed), pct)
        paneRows = [paneS.container]

        let pane = Card("Water on the glass", symbol: "drop.degreesign")
        pane.add(captionLabel("Droplets clinging, running and beading on the screen, as though you were "
                            + "looking at the sky through a window."))
        pane.add(paneCheck)
        pane.add(paneS.container)
        pane.note("Turning this off leaves the sky alone entirely.")
        addCard(pane)
    }

    override func sync(_ c: Config) {
        dockCheck.state = c.wetDock ? .on : .off
        widgetsCheck.state = c.wetWidgets ? .on : .off
        menuBarCheck.state = c.wetMenuBar ? .on : .off
        furnitureS.value = c.furnitureWetness
        paneCheck.state = c.paneWater ? .on : .off
        paneS.value = c.paneWaterAmount
        redraw(c)
    }

    private func redraw(_ c: Config) {
        diagram.wetDock = c.wetDock
        diagram.wetWidgets = c.wetWidgets
        diagram.wetMenuBar = c.wetMenuBar
        diagram.wetPane = c.paneWater
        diagram.furniture = CGFloat(c.furnitureWetness)
        diagram.pane = CGFloat(c.paneWaterAmount)
        // A strength slider with nothing switched on has nothing to strengthen.
        UI.setHidden(furnitureRows, !(c.wetDock || c.wetWidgets || c.wetMenuBar))
        UI.setHidden(paneRows, !c.paneWater)
    }

    @objc private func changed() {
        guard var c = owner?.config else { return }
        c.wetDock = dockCheck.state == .on
        c.wetWidgets = widgetsCheck.state == .on
        c.wetMenuBar = menuBarCheck.state == .on
        c.furnitureWetness = furnitureS.value
        c.paneWater = paneCheck.state == .on
        c.paneWaterAmount = paneS.value
        furnitureS.refresh()
        paneS.refresh()
        redraw(c)
        owner?.commit(c, from: self)
    }
}

// MARK: - Location
//
// Modelled on the Weather app's city picker, which is the native pattern for
// this: a search field that suggests as you type, and underneath it a list of
// the cities you have kept, each showing its own local time. The one table
// swaps between the two — searching replaces the saved list, clearing the field
// brings it back — so there is never a results list and a saved list competing
// for the same space.

final class LocationPane: Pane, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    override var title_: String { "Location" }
    override var symbol: String { "location" }

    private enum Mode { case saved, results, searching, empty }

    private var detectedLabel: NSTextField!
    private var locationButton: NSButton!
    private var searchField: NSSearchField!
    private var table: NSTableView!
    private var statusLabel: NSTextField!
    private var countLabel: NSTextField!
    private var removeButton: NSButton!

    private var mode: Mode = .saved
    /// Guards the selection feedback loop: selecting a row programmatically
    /// fires the same delegate callback a click does, which commits, which
    /// syncs, which selects again — and the app spins forever.
    private var settingSelection = false
    private let search = CitySearch()
    private var results: [MKLocalSearchCompletion] = []
    private var saved: [Place] = []
    private var config = Config()

    /// The completer coalesces internally, so no debounce is needed — results
    /// arrive as you type, which is the whole point.

    override func build() {
        detectedLabel = bodyLabel("—")
        locationButton = NSButton(title: "Use Location Services", target: self,
                                  action: #selector(requestLocation))
        locationButton.bezelStyle = .rounded
        locationButton.font = UI.body

        let yours = Card("Your location", symbol: "location.circle")
        yours.add(row("Detected", detectedLabel))
        yours.add(locationButton)
        addCard(yours)

        searchField = NSSearchField()
        searchField.placeholderString = "Search for a city"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 420).isActive = true

        search.onResults = { [weak self] found in
            guard let self, !self.searchField.stringValue.isEmpty else { return }
            self.results = found
            self.mode = found.isEmpty ? .empty : .results
            self.statusLabel.stringValue = found.isEmpty
                ? "No cities found"
                : "\(found.count) result\(found.count == 1 ? "" : "s") — double-click to add"
            self.table.reloadData()
            self.removeButton.isEnabled = false
        }
        search.onFailure = { [weak self] msg in
            self?.statusLabel.stringValue = msg
        }

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 42
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowActivated)
        let col = NSTableColumn(identifier: .init("city"))
        col.width = 400
        table.addTableColumn(col)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 210).isActive = true

        statusLabel = captionLabel("")
        removeButton = NSButton(title: "Remove City", target: self, action: #selector(removeSelected))
        removeButton.bezelStyle = .rounded
        removeButton.font = UI.body
        countLabel = captionLabel("")

        let cities = Card("Cities", symbol: "building.2")
        cities.add(searchField)
        cities.add(scroll)
        cities.add(statusLabel)
        cities.add(removeButton)
        cities.add(countLabel)
        cities.note("The sun, moon and stars are computed from the selected city, so the wallpaper can "
                  + "show anywhere — not just where you are.")
        addCard(cities)
    }

    // MARK: - Sync

    override func sync(_ c: Config) {
        config = c
        saved = c.allPlaces

        detectedLabel.stringValue = c.place.map {
            "\($0.name)   \(String(format: "%.3f", $0.latitude)), \(String(format: "%.3f", $0.longitude))"
        } ?? "Not set"
        let have = c.place != nil
        locationButton.isEnabled = !have
        locationButton.title = have ? "Location Detected" : "Use Location Services"

        countLabel.stringValue = c.isPlaceListFull
            ? "\(saved.count) of \(Config.maxPlaces) cities — remove one to add another"
            : "\(saved.count) of \(Config.maxPlaces) cities"

        if mode == .saved { table.reloadData(); selectCurrentScene() }
        updateRemoveState()
    }

    private func selectCurrentScene() {
        guard mode == .saved,
              let i = saved.firstIndex(where: { $0.name == config.scenePlace.name }) else { return }
        guard table.selectedRow != i else { return }        // already there
        settingSelection = true
        table.selectRowIndexes([i], byExtendingSelection: false)
        settingSelection = false
    }

    private func updateRemoveState() {
        guard mode == .saved, table.selectedRow >= 0, table.selectedRow < saved.count else {
            removeButton.isEnabled = false; return
        }
        let sel = saved[table.selectedRow].name
        // The detected location is not removable — resetting is what you want.
        removeButton.isEnabled = config.place?.name != sel
                              && config.otherPlaces.contains { $0.name == sel }
    }

    // MARK: - Search

    func controlTextDidChange(_ note: Notification) {
        guard note.object as? NSSearchField === searchField else { return }
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            search.cancel()
            mode = .saved
            results = []
            statusLabel.stringValue = ""
            table.reloadData()
            selectCurrentScene()
            updateRemoveState()
            return
        }
        mode = .searching
        statusLabel.stringValue = "Searching…"
        search.update(q)
    }

    // MARK: - Table

    func numberOfRows(in t: NSTableView) -> Int {
        switch mode {
        case .saved: return saved.count
        case .results: return results.count
        case .searching, .empty: return 0
        }
    }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        // Search hits are completions, not places — they have no coordinates
        // until one is chosen and resolved.
        if mode == .results {
            let c = results[row]
            let title = NSTextField(labelWithString: c.title)
            title.font = .systemFont(ofSize: 13)
            let sub = NSTextField(labelWithString: c.subtitle)
            sub.font = UI.caption
            sub.textColor = .secondaryLabelColor
            let text = NSStackView(views: [title, sub])
            text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let plus = NSImageView()
            plus.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add")
            plus.contentTintColor = .secondaryLabelColor
            let cell = NSStackView(views: [text, spacer, plus])
            cell.orientation = .horizontal; cell.alignment = .centerY; cell.spacing = 8
            cell.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
            return cell
        }

        let place = saved[row]
        let isScene = (mode == .saved) && place.name == config.scenePlace.name
        let isDetected = place.name == config.place?.name

        // Primary line: the city. Secondary: what disambiguates it — its local
        // time for a saved city, its coordinates for a search hit.
        let title = NSTextField(labelWithString: place.name)
        title.font = .systemFont(ofSize: 13, weight: isScene ? .semibold : .regular)

        let sub = NSTextField(labelWithString: subtitle(for: place))
        sub.font = UI.caption
        sub.textColor = .secondaryLabelColor

        let text = NSStackView(views: [title, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        var views: [NSView] = [text]
        do {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            views.append(spacer)
            if isDetected {
                let pin = NSImageView()
                pin.image = NSImage(systemSymbolName: "location.fill", accessibilityDescription: "Detected")
                pin.contentTintColor = .secondaryLabelColor
                views.append(pin)
            }
            if isScene {
                let tick = NSImageView()
                tick.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Showing")
                tick.contentTintColor = .controlAccentColor
                views.append(tick)
            }
        }

        let cell = NSStackView(views: views)
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 8
        cell.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
        return cell
    }

    /// Saved cities show their own local time, which is the fastest way to tell
    /// two similarly named places apart and useful in its own right. Search hits
    /// show coordinates, since their timezone is not confirmed until added.
    private func subtitle(for p: Place) -> String {
        if mode == .saved, let id = p.timeZone, let tz = TimeZone(identifier: id) {
            let f = DateFormatter()
            f.timeZone = tz
            f.dateFormat = "h:mm a"
            let now = Date()
            let mins = (tz.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 60
            let delta = mins == 0 ? "same time"
                : String(format: "%+.1fh", Double(mins) / 60)
            return "\(f.string(from: now))  ·  \(delta)"
        }
        return String(format: "%.3f, %.3f", p.latitude, p.longitude)
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard !settingSelection else { updateRemoveState(); return }
        guard mode == .saved, table.selectedRow >= 0, table.selectedRow < saved.count else {
            updateRemoveState(); return
        }
        let picked = saved[table.selectedRow].name
        // Only commit a real change. Committing an identical config still
        // triggers a full re-sync, which is work for nothing.
        guard picked != config.scenePlace.name else { updateRemoveState(); return }
        var c = config
        c.scenePlaceName = picked
        owner?.commit(c, from: self)
        updateRemoveState()
    }

    @objc private func rowActivated() {
        guard mode == .results, table.clickedRow >= 0, table.clickedRow < results.count else { return }
        statusLabel.stringValue = "Adding…"
        CitySearch.resolve(results[table.clickedRow]) { [weak self] place in
            guard let self else { return }
            guard let place else {
                self.statusLabel.stringValue = "Could not locate that city"
                return
            }
            self.add(place)
        }
    }

    private func add(_ p: Place) {
        var c = config
        guard c.addPlace(p) else {
            let a = NSAlert()
            a.messageText = "City list is full"
            a.informativeText = "Elemental keeps up to \(Config.maxPlaces) cities. Remove one first."
            a.runModal()
            return
        }
        searchField.stringValue = ""
        mode = .saved
        results = []
        statusLabel.stringValue = ""
        owner?.commit(c, from: self)
        table.reloadData()
        selectCurrentScene()
    }

    // MARK: - Buttons

    @objc private func requestLocation() {
        owner?.delegate?.location.onUnavailable = { msg in
            let a = NSAlert()
            a.messageText = "Location unavailable"
            a.informativeText = msg
            a.runModal()
        }
        owner?.delegate?.location.requestOnce()
    }

    @objc private func removeSelected() {
        guard mode == .saved, table.selectedRow >= 0, table.selectedRow < saved.count else { return }
        var c = config
        c.removePlace(named: saved[table.selectedRow].name)
        owner?.commit(c, from: self)
        table.reloadData()
        selectCurrentScene()
    }
}

// MARK: - Sidebar

final class SidebarController: NSViewController {

    var items: [Pane] = []
    var onSelect: ((Int) -> Void)?
    private let table = NSTableView()

    override func loadView() {
        table.headerView = nil
        table.rowHeight = 32
        table.style = .sourceList
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        let col = NSTableColumn(identifier: .init("main"))
        col.width = 176
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Sidebar material, the other half of what makes this read as a modern
        // Mac window. `.behindWindow` so it picks up the desktop, like Finder.
        let fx = NSVisualEffectView()
        fx.material = .sidebar
        fx.blendingMode = .behindWindow
        fx.state = .followsWindowActiveState
        fx.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: fx.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        view = fx
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if table.selectedRow < 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
    }
}

extension SidebarController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let pane = items[row]
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium, scale: .medium))
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let label = NSTextField(labelWithString: pane.title_)
        label.font = .systemFont(ofSize: 13)
        let s = NSStackView(views: [icon, label])
        s.spacing = 8
        s.alignment = .centerY
        s.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        return s
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard table.selectedRow >= 0 else { return }
        onSelect?(table.selectedRow)
    }
}

// MARK: - Window

final class SettingsWindowController: NSObject, NSWindowDelegate {

    weak var delegate: AppDelegate?
    private(set) var config = Config()
    private var window: NSWindow!
    private var panes: [Pane] = []
    private var split: NSSplitViewController!
    private var contentItem: NSSplitViewItem!

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
        build()
    }

    private func build() {
        panes = [
            GeneralPane(),
            SurfacePane(role: .desktop, title: "Home Screen", symbol: "menubar.dock.rectangle",
                        blurb: "The live wallpaper on your desktop — behind your icons, across all Spaces."),
            SurfacePane(role: .lock, title: "Lock Screen", symbol: "lock.display",
                        blurb: "A still behind the password field, refreshed every minute and again the "
                             + "moment you lock. macOS does not allow animation here."),
            SurfacePane(role: .saver, title: "Screen Saver", symbol: "display",
                        blurb: "Fully animated, and the only animated surface that appears at the lock "
                             + "screen — macOS starts it after the idle timer."),
            WaterPane(),
            LocationPane(),
        ]
        panes.forEach { $0.owner = self }

        let sidebar = SidebarController()
        sidebar.items = panes
        sidebar.onSelect = { [weak self] i in self?.select(i) }

        split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 196
        sideItem.maximumThickness = 196
        sideItem.canCollapse = false
        split.addSplitViewItem(sideItem)

        contentItem = NSSplitViewItem(viewController: panes[0])
        split.addSplitViewItem(contentItem)

        let w = NSWindow(contentViewController: split)
        w.title = "Elemental"
        w.styleMask.insert([.closable, .resizable, .fullSizeContentView])
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .visible
        w.isReleasedWhenClosed = false
        w.delegate = self
        // Wide enough that a 400pt hero, a four-thumbnail picker and a slider
        // with its strip all sit comfortably without wrapping.
        w.setContentSize(NSSize(width: 860, height: 700))
        w.minSize = NSSize(width: 800, height: 560)
        w.center()
        window = w
    }

    private func select(_ index: Int) {
        guard index >= 0, index < panes.count else { return }
        let pane = panes[index]
        pane.syncSafely(config)
        split.removeSplitViewItem(contentItem)
        contentItem = NSSplitViewItem(viewController: pane)
        split.addSplitViewItem(contentItem)
        pane.refreshPreviews()
    }

    func show(config: Config) {
        self.config = config
        panes.forEach { $0.syncSafely(config) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Update without stealing focus — used when something outside Settings
    /// changes the config, Location Services resolving being the usual case.
    func refreshIfVisible(config: Config) {
        guard window?.isVisible == true else { return }
        self.config = config
        panes.forEach { $0.syncSafely(config) }
    }

    /// A pane changed something. Push it out, then re-sync the OTHER panes so
    /// dependent controls (city lists, mimic states) stay consistent.
    ///
    /// Not the originating pane. Writing values back into the control the user
    /// currently has hold of makes a slider fight the mouse — every drag frame
    /// the knob is reassigned the value it just reported, and any rounding on
    /// the way through shows up as the knob lagging or snapping behind the
    /// pointer. A pane that changes something is already consistent with
    /// itself; it is the others that need telling.
    ///
    /// `sender` is nil for changes from outside the panes (a resolved location,
    /// a config reload), and then everything syncs as before.
    func commit(_ newConfig: Config, from sender: Pane? = nil) {
        config = newConfig
        delegate?.applyConfig(newConfig)
        for pane in panes where pane !== sender { pane.syncSafely(newConfig) }
    }
}
