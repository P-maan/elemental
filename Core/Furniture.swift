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
    var left: Float { x }
    var right: Float { x + w }

    /// Does a point fall within this surface's horizontal span?
    func spans(_ px: Float) -> Bool { px >= x && px <= x + w }
}

enum Furniture {

    /// Desktop furniture for a screen: the menu bar and the dock.
    static func desktop(screen: NSScreen, widgets: [WidgetRect] = []) -> [Surface] {
        let scale = Float(screen.backingScaleFactor)
        let f = screen.frame, v = screen.visibleFrame
        let W = Float(f.width) * scale
        let H = Float(f.height) * scale

        var out: [Surface] = []

        // Deliberately NOT the menu bar. Water interacting with it looks wrong —
        // it reads as a UI glitch rather than weather, and it is the one strip
        // that is always present regardless of what you are doing.

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

        switch orientation {
        case "left" where leftInset > 1:
            let h = span(along: H)
            out.append(Surface(x: 0, y: (H - h) / 2, w: leftInset, h: h, kind: .dock))
        case "right" where rightInset > 1:
            let h = span(along: H)
            out.append(Surface(x: W - rightInset, y: (H - h) / 2, w: rightInset, h: h, kind: .dock))
        default:
            if bottomInset > 1 {
                let w = span(along: W)
                out.append(Surface(x: (W - w) / 2, y: H - bottomInset, w: w, h: bottomInset, kind: .dock))
            }
        }
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
