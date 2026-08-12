//  Furniture.swift — the things on screen that water has to land on.
//
//  The wallpaper draws BEHIND the dock, the menu bar and the lock screen's
//  clock, so anything rendered at their positions is hidden by them. That is
//  not an obstacle, it is the mechanism: this describes them as collision
//  geometry. Water falls, lands on a surface's top edge, and splashes upward
//  and outward into the space that IS visible. Whatever lands behind the
//  furniture is occluded by it — which is exactly what real water does.
//
//  Nothing here needs Screen Recording. macOS reports the geometry directly:
//
//    menu bar / dock   NSScreen.visibleFrame gives the exact insets, already
//                      accounting for auto-hide and display scale
//    dock extent       item count x tile size from com.apple.dock
//    lock screen       macOS 14+ places the clock centred near the top; the
//                      layout is stable enough to aim splashes at
//
//  A screenshot-derived version could add widgets later; these are the pieces
//  the system will tell us about exactly, so they come first.

import AppKit

/// A rectangle water can land on, in PIXEL coordinates with y increasing
/// downward — matching the simulation and the shader, not AppKit.
struct Surface {
    enum Kind: Int32 { case menuBar = 0, dock = 1, clock = 2, loginBox = 3, widget = 4 }
    var x: Float, y: Float, w: Float, h: Float
    var kind: Kind

    /// How wet THIS piece is allowed to get, 0..1, over and above the global
    /// switch for its kind.
    ///
    /// HANDOFF.md recorded per-element control as blocked, "the engine reads
    /// only global options from Core/Furniture.swift". That was true while a
    /// surface was nothing but a rectangle and a kind: there was no per-instance
    /// anything to attach a value to. It carries a material now, so it can carry
    /// this too.
    ///
    /// Defaults to 1, so a surface built anywhere that does not set it behaves
    /// exactly as it did — the lock screen's clock, the offscreen harness, and
    /// every existing call site included.
    var wetness: Float = 1

    var top: Float { y }
    var bottom: Float { y + h }
    var left: Float { x }
    var right: Float { x + w }

    /// Does this thing have a visible underside for water to hang off?
    ///
    /// The dock sits on the bottom edge of the display, so what runs off its
    /// underside runs off the screen. A widget or the menu bar has pane below
    /// it, and that is where a drip line forms.
    func hasUnderside(screenHeight H: Float) -> Bool { bottom < H - 1 }

    /// Does a point fall within this surface's horizontal span?
    func spans(_ px: Float) -> Bool { px >= x && px <= x + w }

    /// What this thing physically IS, which is not the same question as whether
    /// water is allowed to mark it.
    ///
    /// `kind` was consulted only by `marks()` — a yes/no on whether a surface
    /// gets wet at all — so a dock, a widget, the menu bar and the lock screen's
    /// clock ran byte-identical water physics. They are not the same object. A
    /// dock is a small floating slab of glass with a narrow top; a widget is a
    /// broad glass panel with a flat top you could stand a cup on; the menu bar
    /// is not a ledge at all but an eave flush with the top of the display, with
    /// no top face and only an underside to drip from.
    ///
    /// Four properties are enough to separate them, and each is a real material
    /// property rather than a look:
    ///
    ///   retention  how deep a film the top face holds before it runs over. A
    ///              function of how wide that face is and how sharp its edges
    ///              are — a broad flat top ponds, a narrow rounded one sheds.
    ///   shed       how fast water leaves once it is running. Smooth glass sheds
    ///              fast; anything with texture holds on.
    ///   beadiness  0 spreads into a continuous film, 1 pulls into beads. Clean
    ///              glass is hydrophilic and films; a coated or oily surface
    ///              beads. Screens and their furniture are coated.
    ///   rebound    how much of an impact comes back off. A hard smooth face
    ///              throws spray; a soft or textured one absorbs it.
    var material: SurfaceMaterial { SurfaceMaterial(kind) }
}

/// The physical character of a piece of furniture. See `Surface.material`.
struct SurfaceMaterial {
    var retention: Float
    var shed: Float
    var beadiness: Float
    var rebound: Float

    init(_ kind: Surface.Kind) {
        switch kind {
        case .dock:
            // A small floating slab with a narrow, strongly rounded top. It
            // cannot pond — water reaches an edge almost at once — and being
            // smooth coated glass it sheds fast and beads hard. Hard face, so
            // an impact rebounds well: the dock is the splashiest thing here.
            retention = 0.55; shed = 1.35; beadiness = 0.85; rebound = 1.25
        case .widget:
            // A broad panel with a flat top and a squarer edge. This is the one
            // thing on screen that genuinely PONDS: water has to cross a wide
            // face before it finds an edge, so the film gets deep and the run
            // down the front is continuous rather than a series of drips.
            retention = 1.35; shed = 0.80; beadiness = 0.70; rebound = 0.85
        case .menuBar:
            // Not a ledge. It is flush with the top of the display, so it has no
            // top face to collect anything and only an underside to hang from.
            // Everything that arrives leaves; the eave drip is the whole effect.
            retention = 0.20; shed = 1.60; beadiness = 0.60; rebound = 0.55
        case .clock, .loginBox:
            // Lock-screen furniture is drawn text and a field, not an object
            // with a top surface. It should catch a little and hold almost
            // nothing, or the lock screen grows puddles on its own typography.
            retention = 0.35; shed = 1.20; beadiness = 0.75; rebound = 0.70
        }
    }
}

enum Furniture {

    /// Which desktop elements weather is allowed to mark, and how hard.
    ///
    /// The engine reads this rather than `Config` directly, so the simulation
    /// stays free of file I/O and the screen saver — which cannot read
    /// Application Support at all — still gets a complete, correct answer.
    struct Options: Equatable {
        var dock = true
        var widgets = true
        var menuBar = false
        /// The whole looking-through-a-window layer: beads, runs, pooling.
        var paneWater = true
        /// 0 none, 1 full.
        var furniture: Float = 1
        var pane: Float = 1

        init() {}
        init(_ c: Config) {
            dock      = c.wetDock
            widgets   = c.wetWidgets
            menuBar   = c.wetMenuBar
            paneWater = c.paneWater
            furniture = max(0, min(1, Float(c.furnitureWetness)))
            pane      = max(0, min(1, Float(c.paneWaterAmount)))
        }
    }

    /// The options in force. Hosts may assign this whenever the config changes;
    /// `poll()` below keeps it current on its own if they never do.
    static var options = Options()

    private static var optionsLoadedAt: TimeInterval = -1e9
    private static var configStamp: Date?

    /// Pick up an edited config without the host having to push one.
    ///
    /// A stat every few seconds, and a decode only when the file has actually
    /// changed — so the common case, which is that nothing changed, costs one
    /// syscall a minute of wall-clock time and no allocation. Called from the
    /// simulation's step, which is the one place that runs in every host.
    /// Pin the options and stop `poll()` reading the user's config over them.
    ///
    /// For the offscreen harness only. Without it every test of the water path
    /// silently inherits whatever the developer happens to have switched on in
    /// their own settings, which is how "the splash is not visible" stayed
    /// undiagnosed: the config on this machine has `paneWater` off, and that
    /// turns out to disable splashes too.
    static func pin(_ o: Options) {
        options = o
        pinned = true
    }

    private static var pinned = false

    static func poll(now: TimeInterval) {
        guard !pinned else { return }
        guard now - optionsLoadedAt > 5 || optionsLoadedAt < 0 else { return }
        optionsLoadedAt = now
        let stamp = (try? Config.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        guard optionsLoadedAt < 0 || stamp != configStamp else { return }
        configStamp = stamp
        options = Options(Config.load())
    }

    /// Desktop furniture for a screen: the menu bar and the dock.
    static func desktop(screen: NSScreen, widgets: [WidgetRect] = []) -> [Surface] {
        let scale = Float(screen.backingScaleFactor)
        let f = screen.frame, v = screen.visibleFrame
        let W = Float(f.width) * scale
        let H = Float(f.height) * scale

        var out: [Surface] = []

        // The menu bar is opt-IN and off by default. Water interacting with it
        // reads as a UI glitch rather than as weather, and it is the one strip
        // that is always present regardless of what you are doing — but on a
        // desk where the dock is hidden it is the only lip there is, so the
        // choice belongs to the user rather than to this file.
        //
        // Modelled from the top of the screen down, so its UNDERSIDE is the
        // interesting edge: nothing can land on a strip flush with the top of
        // the display, but water that has run over it hangs off the bottom lip
        // and drips, which is what an eave does.
        let topInset = Float(f.maxY - v.maxY) * scale
        if options.menuBar && topInset > 1 {
            out.append(Surface(x: 0, y: 0, w: W, h: topInset, kind: .menuBar))
        }

        // Dock. visibleFrame gives the thickness exactly; the extent along its
        // edge comes from how many tiles it is holding.
        let d = UserDefaults.standard.persistentDomain(forName: "com.apple.dock") ?? [:]
        let tile = Float((d["tilesize"] as? NSNumber)?.floatValue ?? 55)
        let apps = (d["persistent-apps"] as? [Any])?.count ?? 0
        let others = (d["persistent-others"] as? [Any])?.count ?? 0
        let items = Float(max(1, apps + others + 1))          // +1 for Finder
        let orientation = (d["orientation"] as? String) ?? "bottom"

        let bottomInset = Float(v.minY - f.minY) * scale
        let leftInset   = Float(v.minX - f.minX) * scale
        let rightInset  = Float(f.maxX - v.maxX) * scale

        // The dock PANEL, not the whole reserved strip.
        //
        // `visibleFrame` reserves the dock's region INCLUDING the margin macOS
        // leaves around it, so a surface built straight from the inset runs all
        // the way to the edge of the display. Two things followed from that, and
        // both are user-visible:
        //
        //   * `hasUnderside` is `bottom < H - 1`, so a dock touching the bottom
        //     edge has no underside and `shedDrips` can never shed one drop off
        //     it. "No water running down the dock" was not a rendering problem;
        //     the geometry said there was nowhere for it to run to.
        //   * the strip is taller than the panel, so splashes aim at a lip that
        //     is above where the dock's real top edge is.
        //
        // macOS floats the panel with a margin all round. The margin scales with
        // the tile size rather than being fixed, and a sixth of the reserved
        // depth matches it closely across tile sizes from 32 to 128.
        let dockGap = max(2.0 as Float, min(bottomInset, max(leftInset, rightInset)) * 0.16)

        // Extent along the dock's edge.
        //
        // This counted persistent apps + persistent others + Finder, and came
        // out about a quarter short of the real panel. Three things it missed:
        // the separator between the app and file sections, the Trash — which
        // lives in neither persistent list — and `show-recents`, which appends
        // up to three more tiles and is on by default.
        let showsRecents = (d["show-recents"] as? NSNumber)?.boolValue ?? true
        let recentCount = showsRecents ? 3 : 0
        // Trash, plus a separator's worth of width for each section break.
        let extras = Float(1 + recentCount) + 1.2
        func span(along available: Float) -> Float {
            let tiles = (items + extras) * (tile * scale * 1.09)
            // The panel's own padding, which does not scale with item count.
            return min(available * 0.96, tiles + tile * scale * 0.55)
        }

        switch options.dock ? orientation : "off" {
        case "left" where leftInset > 1:
            let h = span(along: H)
            out.append(Surface(x: dockGap, y: (H - h) / 2,
                               w: max(1, leftInset - dockGap * 2), h: h, kind: .dock))
        case "right" where rightInset > 1:
            let h = span(along: H)
            out.append(Surface(x: W - rightInset + dockGap, y: (H - h) / 2,
                               w: max(1, rightInset - dockGap * 2), h: h, kind: .dock))
        case "off":
            break                                       // dock opted out
        default:
            if bottomInset > 1 {
                let w = span(along: W)
                // Inset from the bottom by the panel's own margin, so the dock
                // HAS an underside and water can run off it into the gap the way
                // it does off any other ledge.
                out.append(Surface(x: (W - w) / 2, y: H - bottomInset + dockGap,
                                   w: w, h: max(1, bottomInset - dockGap * 2), kind: .dock))
            }
        }
        guard options.widgets else { return out }
        // Desktop widgets. macOS does not publish their positions, so these
        // come from config — populated by hand today, and the place a
        // screenshot-derived detector would write to later.
        out.append(contentsOf: widgets.map {
            Surface(x: $0.x * W, y: $0.y * H, w: $0.w * W, h: $0.h * H,
                    kind: .widget, wetness: $0.wetness)
        })
        return out
    }

    /// Lock screen and screen-saver furniture. Positions are estimates from the
    /// macOS 14+ layout — the clock sits centred a little above a third of the
    /// way down, with the login field below it. Close enough to aim splashes
    /// at, and the real UI draws over the top of whatever we get slightly wrong.
    static func lockScreen(width W: Float, height H: Float, includeLoginBox: Bool) -> [Surface] {
        var out: [Surface] = []
        let clockW = W * 0.42, clockH = H * 0.17
        out.append(Surface(x: (W - clockW) / 2, y: H * 0.10, w: clockW, h: clockH, kind: .clock))
        if includeLoginBox {
            let boxW = W * 0.20, boxH = H * 0.12
            out.append(Surface(x: (W - boxW) / 2, y: H * 0.62, w: boxW, h: boxH, kind: .loginBox))
        }
        return out
    }
}


/// A desktop widget's position as fractions of the screen, so it survives a
/// resolution change. Config holds these until detection can supply them.
struct WidgetRect: Codable, Equatable {
    var x: Float, y: Float, w: Float, h: Float

    /// Per-widget wetness, 0 dry to 1 fully. Optional in the JSON so every
    /// config written before this existed still decodes, and absent means 1 —
    /// which is what those configs meant.
    var wetness: Float = 1

    init(x: Float, y: Float, w: Float, h: Float, wetness: Float = 1) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.wetness = wetness
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Float.self, forKey: .x)
        y = try c.decode(Float.self, forKey: .y)
        w = try c.decode(Float.self, forKey: .w)
        h = try c.decode(Float.self, forKey: .h)
        wetness = (try? c.decodeIfPresent(Float.self, forKey: .wetness)) .flatMap { $0 } ?? 1
    }
}
