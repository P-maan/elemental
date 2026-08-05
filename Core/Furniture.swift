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
    static func poll(now: TimeInterval) {
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

        // Tiles shrink once the dock would overflow its edge, so cap the span.
        func span(along available: Float) -> Float {
            min(available * 0.96, items * (tile * scale * 1.09) + tile * scale)
        }

        switch options.dock ? orientation : "off" {
        case "left" where leftInset > 1:
            let h = span(along: H)
            out.append(Surface(x: 0, y: (H - h) / 2, w: leftInset, h: h, kind: .dock))
        case "right" where rightInset > 1:
            let h = span(along: H)
            out.append(Surface(x: W - rightInset, y: (H - h) / 2, w: rightInset, h: h, kind: .dock))
        case "off":
            break                                       // dock opted out
        default:
            if bottomInset > 1 {
                let w = span(along: W)
                out.append(Surface(x: (W - w) / 2, y: H - bottomInset, w: w, h: bottomInset, kind: .dock))
            }
        }
        guard options.widgets else { return out }
        // Desktop widgets. macOS does not publish their positions, so these
        // come from config — populated by hand today, and the place a
        // screenshot-derived detector would write to later.
        out.append(contentsOf: widgets.map {
            Surface(x: $0.x * W, y: $0.y * H, w: $0.w * W, h: $0.h * H, kind: .widget)
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
}
