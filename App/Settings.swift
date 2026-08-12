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

    /// The pinned area above the scroller. Empty and zero-height until a pane
    /// puts something in it.
    ///
    /// The preview used to be the first card in the scrolling column, which put
    /// it off the top of the window the moment you scrolled down to reach the
    /// control you wanted to drag — and the preview matters MOST while that
    /// control is moving. So it is parented outside the scroll view instead.
    /// Nothing about how previews render or cache changes; this is only where
    /// the view hangs.
    private let headerHost = NSVisualEffectView()
    private let headerContent = NSStackView()
    private var headerCollapse: NSLayoutConstraint!

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

        // ---- the pinned header
        //
        // Its own material and a hairline under it, so it reads as a header
        // rather than as content that failed to scroll.
        headerHost.material = .headerView
        headerHost.blendingMode = .withinWindow
        headerHost.state = .followsWindowActiveState
        headerHost.translatesAutoresizingMaskIntoConstraints = false

        headerContent.orientation = .horizontal
        headerContent.alignment = .centerY
        headerContent.spacing = 16
        headerContent.translatesAutoresizingMaskIntoConstraints = false

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false

        headerHost.addSubview(headerContent)
        headerHost.addSubview(hairline)

        backdrop.addSubview(headerHost)
        backdrop.addSubview(scroll)

        // Collapsed until `installHeader` puts something in it. A pane with no
        // preview then looks exactly as it did before.
        headerCollapse = headerHost.heightAnchor.constraint(equalToConstant: 0)
        headerCollapse.isActive = true

        NSLayoutConstraint.activate([
            headerHost.topAnchor.constraint(equalTo: backdrop.topAnchor),
            headerHost.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),

            headerContent.topAnchor.constraint(equalTo: headerHost.topAnchor, constant: 14),
            headerContent.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor, constant: -14),
            headerContent.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor,
                                                   constant: UI.paneInset),
            headerContent.trailingAnchor.constraint(lessThanOrEqualTo: headerHost.trailingAnchor,
                                                    constant: -UI.paneInset),

            hairline.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: headerHost.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor),

            // The scroller takes everything below it. Its content is laid out
            // against its own bounds, so the header cannot eat the last card —
            // no content inset is involved.
            scroll.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        view = backdrop
        build()
    }

    /// Pin `v` above the scroller, with `caption` beside it.
    ///
    /// Beside rather than under: the header's height is the one thing that has
    /// to stay in hand — everything it takes comes out of the controls on a
    /// short window — and a wide window has room to spare horizontally. So the
    /// picture sets the height and the words fill the space next to it.
    func installHeader(_ v: NSView, caption: String) {
        headerCollapse.isActive = false
        headerContent.addArrangedSubview(v)
        let cap = captionLabel(caption, width: 300)
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        headerContent.addArrangedSubview(cap)
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

    /// Put a hero in the pane's pinned header, with its caption beside it.
    ///
    /// Drawn smaller than the render is: still 800x500 pixels of scene (one
    /// shared renderer, one cache entry) shown at 320x200 points, because the
    /// header's height comes straight out of the space the controls have on a
    /// short window. A preview you can see while you drag the slider beats a
    /// bigger one you cannot.
    func installHero(_ caption: String) {
        let h = HeroPreview(points: HeroPreview.pinnedPoints)
        hero = h
        installHeader(h, caption: caption)
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
    /// Supplied rather than made here, so a pane can hand in a `DetentSlider`
    /// and get the same row with haptics on it.
    let slider: NSSlider
    let label = NSTextField(labelWithString: "")
    let box = NSStackView()
    /// The full row, for showing and hiding.
    var container: NSView!
    private let format: (Double) -> String

    init(range: ClosedRange<Double>, format: @escaping (Double) -> String,
         slider: NSSlider = NSSlider()) {
        self.slider = slider
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
    private var liveWeatherCheck: NSButton!
    private var fpsPop: NSPopUpButton!
    private var speedPop: NSPopUpButton!
    private var replayPop: NSPopUpButton!
    private var occludedCheck: NSButton!
    private var lowPowerCheck: NSButton!
    private var hdrCheck: NSButton!
    private var lockSyncCheck: NSButton!

    private var depthS: LabelledSlider!
    private var emphS: LabelledSlider!
    private var lightS: LabelledSlider!
    private var refractS: LabelledSlider!
    private var dispersS: LabelledSlider!
    private var frostS: LabelledSlider!
    private var splayS: LabelledSlider!
    private var shimmerS: LabelledSlider!
    private var riseS: LabelledSlider!
    private var iconPicker: AppIconPicker!
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
        // No strip for this one. The three tiles under every other relief
        // slider show what the setting looks like, and what this setting looks
        // like is three identical pictures — it is a rate, and a still cannot
        // hold one. A caption is the honest control here.
        riseS = slider("Rise", 0...1, #selector(changed)) {
            $0 < 0.005 ? "instant" : String(format: "%.1fs", 0.08 + $0 * $0 * 2.4)
        }

        let relief = Card("Relief", symbol: "cube")
        relief.add(captionLabel("Every cell is a block pushed out of the wall by its own brightness, so "
                              + "the clouds and the moon emboss the mosaic instead of only colouring it."))
        relief.add(reliefRow("Depth", depthS, \.depth))
        relief.add(reliefRow("Emphasis", emphS, \.emphasis))
        relief.add(reliefRow("Light", lightS, \.light))
        relief.add(reliefRow("Splay", splayS, \.splay))
        relief.add(riseS.container)
        relief.note("Depth is how far the blocks stand out. Emphasis decides whether they follow "
                  + "features or plain tone. Light shades their side faces and the crevices between "
                  + "them. Splay unsettles the courses so the wall is not perfectly regular.")
        relief.note("Rise is the one that moves: how long a block takes to grow or sink to a new "
                  + "height as the sky changes, rather than being at it in the next frame. Instant "
                  + "is how it behaved before.")
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
        // The first-run flow, on demand.
        //
        // Worth having for more than curiosity: it is the one place that walks
        // the permissions in the order they actually matter, and the permissions
        // are exactly what an ad-hoc signed build keeps losing — a rebuild mints
        // a new code identity and macOS forgets the Location grant (trap 9). So
        // "run it again" is the shortest honest answer to "the sky is drawn for
        // the wrong city", and it is also how you show somebody the app.
        liveWeatherCheck = check("Follow the real weather", #selector(liveWeatherToggled))
        startup.add(liveWeatherCheck)
        startup.note("Off draws a clear calm day, whatever it is doing outside. The sun and moon "
                   + "still follow the real sky.")
        let redo = NSButton(title: "Run First-Run Setup Again…", target: self,
                            action: #selector(replayOnboarding))
        redo.bezelStyle = .rounded
        startup.add(redo)
        addCard(startup)

        // ---- icon
        iconPicker = AppIconPicker()
        iconPicker.onPick = { [weak self] style in
            guard let self, var c = self.owner?.config else { return }
            c.appIcon = style
            self.iconPicker.select(style)
            self.owner?.commit(c, from: self)
        }
        let icon = Card("Icon", symbol: "app.badge")
        icon.add(iconPicker)
        icon.note("Which mark Elemental wears in Finder, Spotlight and its own alerts. Mark is the "
                + "default. The choice is applied as a custom icon on the app bundle, so it does not "
                + "touch anything inside it that is code-signed.")
        addCard(icon)

        // ---- motion
        fpsPop = popup(Self.fpsChoices.map { "\($0) fps" }, #selector(changed))
        speedPop = popup(Self.speedChoices.map(\.0), #selector(changed))
        replayPop = popup(Self.replayChoices.map(\.0), #selector(changed))
        shimmerS = slider("Shimmer", 0...1, #selector(changed), pct)
        let motion = Card("Motion", symbol: "waveform")
        motion.add(shimmerS.container)
        motion.note("A slow drift of light across the wall. Costs frames — a still scene can "
                  + "otherwise be drawn a handful of times a second, and movement cannot.")
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

        // ---- HDR
        //
        // Kept honest rather than kept quiet. macOS does not hand extended
        // dynamic range to a window below the normal window level, and the
        // wallpaper sits at the desktop level, far below it — so on the desktop
        // this setting is measured, found to be refused, and says so.
        //
        // The screen saver DOES run above the normal level (measured: level
        // 1000 is granted the display's full headroom), so it is the one
        // surface that could use this. It does not yet — Saver/ElementalSaver
        // still builds its renderer and layer as bgra8Unorm/sRGB, and wiring it
        // is the same three lines used in WallpaperSurface.
        hdrCheck = check("Let the sun, the moon and lightning go brighter than white",
                         #selector(hdrToggled))
        let hdr = Card("Brightness beyond white", symbol: "sun.max.trianglebadge.exclamationmark")
        hdr.add(hdrCheck)
        hdr.note("Experimental. Renders the genuinely bright things — the sun's disc, lightning, the "
               + "moon — into the display's HDR headroom instead of clipping them at white. It works "
               + "the GPU noticeably harder and is not recommended for long stretches on battery.")
        hdr.rule()
        hdr.note("Honest caveat, and please read it before turning this on: macOS only grants HDR "
               + "headroom to windows at or above the normal window level, and a wallpaper has to sit "
               + "below the desktop icons to be a wallpaper at all. Measured on this Mac, the very "
               + "same layer is given no headroom at the desktop level and the display's full "
               + "headroom one level above it. So on the desktop this currently costs power and "
               + "changes nothing you can see. Elemental asks anyway and reads back what it was "
               + "actually granted, so if a future macOS allows it, it starts working by itself.")
        addCard(hdr)

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
        liveWeatherCheck.state = c.liveWeather ? .on : .off
        shimmerS.value = c.shimmer
        fpsPop.selectItem(at: Self.fpsChoices.firstIndex(of: c.maxFPS) ?? 2)
        speedPop.selectItem(at: Self.speedChoices.firstIndex { abs($0.1 - c.motionSpeed) < 0.001 } ?? 3)
        replayPop.selectItem(at: c.playbackOnWake
            ? (Self.replayChoices.firstIndex { abs($0.1 - c.playbackMaxSeconds) < 0.001 } ?? 2) : 0)
        occludedCheck.state = c.renderWhenOccluded ? .on : .off
        lowPowerCheck.state = c.lowPowerOnBattery ? .on : .off
        hdrCheck.state = c.hdr ? .on : .off
        lockSyncCheck.state = c.syncLockScreen ? .on : .off
        iconPicker.select(c.appIcon)
        depthS.value = c.reliefDepth
        emphS.value = c.emphasis
        lightS.value = c.lightIntensity
        splayS.value = c.splay
        riseS.value = c.reliefRise
        refractS.value = c.refraction
        dispersS.value = c.dispersion
        frostS.value = c.frost
        // The desktop's finish decides it: the lock screen and saver can differ,
        // but this is one shared wall and the pane it lives on is the general one.
        UI.setHidden([glassCard], c.finish != .glass)
        refreshPreviewsDebounced()
    }

    @objc private func liveWeatherToggled() {
        guard var c = owner?.config else { return }
        c.liveWeather = liveWeatherCheck.state == .on
        owner?.commit(c, from: self)
    }

    @objc private func replayOnboarding() {
        // Cleared and saved BEFORE asking to present, so a flow that is quit
        // half way still counts as un-onboarded and can be resumed, rather than
        // the flag being set by the act of opening it.
        guard var c = owner?.config else { return }
        c.hasOnboarded = false
        owner?.commit(c, from: self)
        NSApp.sendAction(#selector(AppDelegate.startOnboarding), to: nil, from: nil)
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

    /// Turning HDR ON warns first; turning it off is free and silent.
    @objc private func hdrToggled() {
        if hdrCheck.state == .on {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "This will hammer the GPU."
            a.informativeText =
                "Drawing into HDR headroom means a 16-bit floating point surface, a wider colour "
                + "space and an extra compositor pass, every frame, all day. Expect the GPU to work "
                + "considerably harder and the machine to run warmer. Not recommended for prolonged "
                + "use on battery.\n\n"
                + "It is experimental and off by default for that reason.\n\n"
                + "Note also that macOS refuses HDR headroom to the desktop wallpaper — it only "
                + "grants it at or above the normal window level, and a wallpaper must sit below "
                + "that. So on the desktop this setting will cost you the power and change nothing "
                + "you can see. It is here so the engine is ready the day that changes."
            a.addButton(withTitle: "Turn It On Anyway")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else {
                hdrCheck.state = .off
                return
            }
            let after = NSAlert()
            after.messageText = "Quit and reopen Elemental to apply."
            after.informativeText =
                "The render pipelines are compiled for one pixel format, so the change takes effect "
                + "the next time Elemental starts."
            after.runModal()
        }
        changed()
    }

    @objc private func changed() {
        guard var c = owner?.config else { return }
        c.hdr = hdrCheck.state == .on
        c.maxFPS = Self.fpsChoices[max(0, min(Self.fpsChoices.count - 1, fpsPop.indexOfSelectedItem))]
        c.motionSpeed = Self.speedChoices[max(0, min(Self.speedChoices.count - 1, speedPop.indexOfSelectedItem))].1
        let rp = Self.replayChoices[max(0, min(Self.replayChoices.count - 1, replayPop.indexOfSelectedItem))]
        c.playbackOnWake = rp.1 > 0
        if rp.1 > 0 { c.playbackMaxSeconds = rp.1 }
        c.renderWhenOccluded = occludedCheck.state == .on
        c.lowPowerOnBattery = lowPowerCheck.state == .on
        c.syncLockScreen = lockSyncCheck.state == .on
        c.reliefDepth = depthS.value
        c.shimmer = shimmerS.value
        c.emphasis = emphS.value
        c.lightIntensity = lightS.value
        c.splay = splayS.value
        c.reliefRise = riseS.value
        c.refraction = refractS.value
        c.dispersion = dispersS.value
        c.frost = frostS.value
        for s in [depthS, emphS, lightS, splayS, riseS, refractS, dispersS, frostS] { s?.refresh() }
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

    /// Density by grabbing it — the primary control. `grip` is exposed for the
    /// offscreen harness, which cannot click.
    private(set) var grip: DensityGripView!
    private var densityLabel: NSTextField!

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
            self.setRows(Int(v))
            self.write(self.collect())
        }

        // Density by direct manipulation. See DensityGrip.swift — the field and
        // stepper above stay as the typeable, keyboard-reachable way in.
        grip = DensityGripView()
        grip.onLiveChange = { [weak self] q in
            guard let self else { return }
            self.setRows(q)
            // Live half only: the picture follows the drag, the config settles
            // on mouse-up. Committing per step would re-sync every other pane
            // on every detent crossed.
            self.write(self.collect(), live: true)
        }
        grip.onCommit = { [weak self] q in
            guard let self else { return }
            self.setRows(q)
            self.write(self.collect())
        }
        densityLabel = captionLabel("", width: 300)

        let mosaic = Card("Mosaic", symbol: "square.grid.3x3")
        mosaic.add(captionLabel("The shape of a cell and whether it is glass or flat. Pick the one that "
                              + "looks right — the four are shown exactly as they will draw."))
        mosaic.add(styleRow)
        mosaic.rule()
        mosaic.add(captionLabel("Density — drag the corner of the box to stretch the cells, or scroll "
                              + "over it. It clicks as it passes each size."))
        mosaic.add(grip)
        mosaic.add(densityLabel)
        mosaic.add(row("Rows", rowsBox))
        mosaic.add(densityStrip)
        mosaic.note("Cells down the screen. The Pi uses 36; more rows is a finer grid. The engine picks "
                  + "a cell pitch that divides your display exactly, so the count it settles on can be "
                  + "a row or two off what was asked for — the box shows the real one.")

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
        setRows(st.gridRows)
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

    /// Put a row count into every control that shows one, without committing.
    ///
    /// The grip is the odd one out: it snaps to a density the display can
    /// actually produce, so the number it ends up on may not be the one handed
    /// in — and the read-out has to say the real one or the control looks
    /// broken when it "moves on its own". See DensityGrip.swift.
    private func setRows(_ q: Int) {
        let v = max(12, min(120, q))
        rowsField.integerValue = v
        rowsStepper.integerValue = v
        grip.setRequested(v)
        let s = grip.step
        densityLabel.stringValue = String(
            format: "%d rows on your display — %.0fpx cells.", s.rows, s.cellPixels)
    }

    /// The grip's picture is live, like the hero: it IS the control, so it may
    /// not be debounced away.
    override func updateLivePreview(_ c: Config) {
        super.updateLivePreview(c)
        if let spec = heroSpec(c) { grip?.show(spec) }
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
            // The four tiles are PRESETS over the three axes, not a shape/finish
            // pair any more. `dot` always meant round AND size-carries-tone; it
            // is written out here rather than left implied.
            s.material = (combo.1 == .flat) ? .matte : .glass
            s.rounding = (combo.0 == .dot) ? 1 : 0
            s.halftone = (combo.0 == .dot) ? 1 : 0
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

    /// `live` is the cheap half of a drag: the picture follows, nothing is
    /// committed and no other pane is re-synced. The commit lands on mouse-up.
    private func write(_ st: Config.SurfaceStyle, live: Bool = false) {
        guard var c = owner?.config else { return }
        switch role {
        case .desktop:
            c.shape = st.shape; c.finish = st.finish; c.gridRows = st.gridRows
            c.material = (st.finish == .flat) ? .matte : .glass
            c.rounding = (st.shape == .dot) ? 1 : 0
            c.halftone = (st.shape == .dot) ? 1 : 0
            c.poster = st.poster; c.headingMode = st.headingMode
            c.facingAz = st.facingAz; c.scenePlaceName = st.scenePlaceName
        case .lock:  c.lock = st
        case .saver: c.saver = st
        }
        updateLivePreview(c)
        guard !live else { return }
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
        setRows(rowsStepper.integerValue)
        write(collect())
    }

    @objc private func rowsTyped() {
        setRows(rowsField.integerValue)
        write(collect())
    }

    static func bearing(_ deg: Double) -> String {
        let names = ["N","NE","E","SE","S","SW","W","NW"]
        return String(format: "%3d°  %@", Int(deg), names[Int((deg / 45).rounded()) % 8])
    }
}

// MARK: - Elements
//
// The pane that owns the furniture on your screen — where it is, and what
// weather is allowed to do to it — lives in ElementsPane.swift. It replaces the
// old Weather pane, which had the same switches but no way to say where the
// things being switched actually were.

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
        // The recovery path has to stay reachable.
        //
        // This was `isEnabled = (c.place == nil)`: the button switched itself
        // off the moment any place was stored and read "Location Detected"
        // forever after. That is the one state in which it is most needed — a
        // stored place is what you have when location worked ONCE and then
        // stopped, which for an ad-hoc signed build is after every rebuild. The
        // user was told location was working while the app had no grant at all
        // and no way to ask for one.
        //
        // So: enabled whenever a fresh fix could actually help. Only a live,
        // authorised, currently-followed location earns the passive label.
        let blocked = owner?.delegate?.locationBlocked ?? false
        let following = c.place != nil && c.isShowingDetectedPlace && !blocked
        locationButton.isEnabled = !following
        locationButton.title = following ? "Location Detected"
                             : (c.place == nil ? "Use Location Services"
                                               : "Update My Location")

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
        // Stand the placement overlay down first — see .elementalPermissionPrompt.
        NotificationCenter.default.post(name: .elementalPermissionPrompt, object: nil)
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
            ElementsPane(),
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

    /// Order the settings window out without tearing it down.
    ///
    /// Used when the onboarding flow takes the screen: it covers the display, so
    /// a settings window left open behind it is a window the user cannot see and
    /// cannot reach, and closing it outright would throw away the pane they were
    /// on for no reason.
    func hide() { window?.orderOut(nil) }

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
    /// The window and its panes, for the offscreen verification harness.
    ///
    /// Reaching them is the only way to prove the window builds, lays out and
    /// syncs without putting it on the user's screen — and "the settings window
    /// crashes because a pane's controls are still nil" is a bug this project
    /// has actually had. Nothing in the app calls this.
    var inspectable: (window: NSWindow, panes: [Pane]) { (window, panes) }

    func commit(_ newConfig: Config, from sender: Pane? = nil) {
        config = newConfig
        delegate?.applyConfig(newConfig)
        for pane in panes where pane !== sender { pane.syncSafely(newConfig) }
    }
}
