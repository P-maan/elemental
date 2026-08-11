//  WidgetSetupOverlay.swift — point at your widgets instead of guessing at them.
//
//  macOS publishes no API for where desktop widgets are. Everything else the
//  engine needs to collide with, it can ask the system for: the menu bar and the
//  dock come out of `NSScreen.visibleFrame` and com.apple.dock exactly. Widgets
//  come from nowhere, so they have been coming from `FurnitureDetector` — a
//  contrast heuristic run over a screenshot, which finds roughly half of them,
//  invents a couple, and then has to be corrected by hand on a 320pt miniature.
//
//  This is the other way round, and it is the user's idea: stop inferring, and
//  let them SHOW us. A translucent sheet over the real desktop, drag a box round
//  each widget, done. No screenshot, no detector, no guessing.
//
//  ---- Why snapping is the whole feature
//
//  A freehand rectangle drawn over a widget is a worse measurement than the
//  detector's, because a hand is not a ruler and nobody drags to the pixel. But
//  a macOS desktop widget cannot be an arbitrary size: there are exactly FOUR,
//  they are fixed sizes in points, and the system lays them out on a grid. So
//  the drawn rectangle never has to be believed — only classified. Drag
//  something roughly 300 by 150 and it becomes a medium widget, exactly 329 x
//  155 points, which is exactly what is on screen. The user supplies the
//  position, which they know and we cannot; the presets supply the size, which
//  they do not know and we can.
//
//  The model here holds a size PRESET and an origin, never a free rectangle, so
//  a placement that is not one of the four sizes cannot be expressed at all.
//  That includes rectangles adopted from an existing config: opening this over
//  detector output snaps every one of them, and the user sees that happen before
//  anything is saved.
//
//  ---- Click-through
//
//  The overlay ignores the mouse whenever Elemental is not the active app, so it
//  is a sheet of glass over a working desktop rather than a modal trap: click
//  past it to move a real widget, then come back. It sits at `.floating`, BELOW
//  the menu bar level, on purpose — Elemental is an LSUIElement app with no
//  Cmd-Tab entry, so the menu bar item is the only way back in once clicks are
//  passing through, and an overlay that covered it would strand the user behind
//  a window they could no longer click.

import AppKit

// MARK: - The four sizes

/// A macOS desktop widget's size. There are four of them and no others.
///
/// The point sizes are WidgetKit's macOS table, not a derivation. They are the
/// same on every Mac — a widget is not scaled to the display — so on a screen of
/// a given size in points these are also fixed FRACTIONS of that screen, which
/// is what `Config.widgets` stores.
///
/// The cell counts describe the layout grid the sizes sit on. Solving the two
/// horizontal sizes for a cell and a gutter gives 68pt cells with 19pt between
/// them (2*68 + 19 = 155, 4*68 + 3*19 = 329); the vertical run is not the same
/// pitch (60pt rows, 35pt gutters), because a widget's height carries a header
/// the width does not. They are here for the labels and for `gutter` below, not
/// to generate the sizes — the sizes are the primary source.
enum DesktopWidgetSize: CaseIterable {
    case small, medium, large, extraLarge

    /// Points, as WidgetKit defines them for macOS.
    var points: CGSize {
        switch self {
        case .small:      return CGSize(width: 155, height: 155)
        case .medium:     return CGSize(width: 329, height: 155)
        case .large:      return CGSize(width: 329, height: 345)
        case .extraLarge: return CGSize(width: 677, height: 345)
        }
    }

    /// Cells across and down, for the label. "4 × 2" is how the user thinks of a
    /// medium widget; "329 × 155" is not.
    var cells: (across: Int, down: Int) {
        switch self {
        case .small:      return (2, 2)
        case .medium:     return (4, 2)
        case .large:      return (4, 4)
        case .extraLarge: return (8, 4)
        }
    }

    var name: String {
        switch self {
        case .small:      return "Small"
        case .medium:     return "Medium"
        case .large:      return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    /// The next size round, for the double-click cycle.
    var next: DesktopWidgetSize {
        let all = DesktopWidgetSize.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// The gap macOS leaves between two widgets side by side, in points. Falls
    /// out of the cell solve above; used as a snap target so two widgets placed
    /// next to each other land at the spacing the system would have given them.
    static let gutter: CGFloat = 19

    /// This preset in BACKING PIXELS on a given screen — the units the engine's
    /// collision geometry ends up in, and the honest thing to show the user
    /// beside the point size on a Retina display.
    func pixels(on screen: NSScreen) -> CGSize {
        let s = screen.backingScaleFactor
        return CGSize(width: points.width * s, height: points.height * s)
    }

    /// Which preset a drawn rectangle meant.
    ///
    /// Distance in absolute points, summed over both dimensions, and NOT
    /// anything cleverer:
    ///
    ///   * Aspect ratio alone cannot do it. Small is 1.00 and large is 0.95;
    ///     medium is 2.12 and extra large is 1.96. Two pairs, indistinguishable
    ///     within each pair, so a match on shape would coin-flip between a
    ///     widget and one four times its area.
    ///   * Relative error biases toward the big presets — halfway between 329
    ///     and 677 it still prefers 677, because 227/677 is less than 121/329.
    ///     The presets are absolute point sizes on a screen of a known size, so
    ///     absolute distance is the metric that matches what the eye is doing.
    static func nearest(to size: CGSize) -> DesktopWidgetSize {
        var best = DesktopWidgetSize.small
        var bestScore = CGFloat.greatestFiniteMagnitude
        for candidate in allCases {
            let p = candidate.points
            let score = abs(size.width - p.width) + abs(size.height - p.height)
            if score < bestScore { bestScore = score; best = candidate }
        }
        return best
    }
}

/// One placed widget: a preset and a top-left corner in view points, y down.
///
/// Deliberately not a rectangle. See the header — the size is never free.
struct WidgetPlacement: Equatable {
    var size: DesktopWidgetSize
    var origin: CGPoint

    var rect: CGRect { CGRect(origin: origin, size: size.points) }

    /// Move so the rectangle is centred where it is now but takes a new size.
    func resized(to s: DesktopWidgetSize) -> WidgetPlacement {
        let r = rect
        return WidgetPlacement(size: s,
                               origin: CGPoint(x: r.midX - s.points.width / 2,
                                               y: r.midY - s.points.height / 2))
    }
}

// MARK: - The canvas

/// The full-screen drawing surface: dim wash, punched-out placements, and all
/// of the pointer and keyboard handling.
///
/// Coordinates are the view's own points, and the view is exactly the size of
/// the screen in points, so a placement's rectangle IS its position on the
/// screen and the presets are usable as literal constants. Flipped, so y counts
/// down from the top — the convention `WidgetRect`, `Furniture` and the
/// simulation all share, which means the conversion at save time is a divide
/// and nothing else.
final class WidgetSetupCanvas: NSView {

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private(set) var placed: [WidgetPlacement] = [] { didSet { needsDisplay = true } }
    private var selection: Int? { didSet { if selection != oldValue { needsDisplay = true } } }

    /// The screen this is covering, for the pixel figures in the labels.
    var screen: NSScreen?

    /// True while Elemental is not the active app and clicks are going straight
    /// through to the desktop. Drawn differently so the state is visible rather
    /// than something the user discovers by clicking and having nothing happen.
    var isPassive = false { didSet { needsDisplay = true } }

    /// Fires whenever the placement count changes, for the HUD's running total.
    var onChange: (() -> Void)?

    // ---- drag state

    private enum Drag {
        case none
        /// Rubber-banding a new rectangle. `anchor` is where the mouse went
        /// down and is the corner that stays put when the size snaps.
        case creating(anchor: CGPoint, current: CGPoint)
        /// Moving an existing one. `grab` is the pointer's offset inside it.
        case moving(index: Int, grab: CGSize)
    }
    private var drag: Drag = .none

    /// Exactly the placement a mouse-up would commit, kept up to date by the
    /// drag rather than worked out again in `draw`.
    ///
    /// Two reasons it lives here and not in the drawing. Snapping fires haptics
    /// and records guides, and neither belongs on a redraw — a window resize
    /// would buzz. And the preview has to be the SAME rectangle that gets
    /// committed, snap included: a preview that showed the unsnapped position
    /// would jump the moment the button came up, which is the one thing a
    /// preview exists to prevent.
    private var pending: WidgetPlacement?

    /// Below this, a drag was a click. The smallest preset is 155pt across, so
    /// there is no risk of confusing a deliberate small widget with a stray
    /// twitch on the way to selecting one.
    private let minDrag: CGFloat = 22

    // ---- snapping, same shape as DesktopGridView's

    private struct Guide: Equatable { var vertical: Bool; var value: CGFloat }
    private var guides: [Guide] = []
    private var engaged: Set<String> = []

    /// Points, not fractions: this canvas is drawn at 1:1 with the screen, so a
    /// fixed distance here is a fixed distance to the hand.
    private let snapTolerance: CGFloat = 8

    /// How far in from the screen edge macOS parks the outermost widget column.
    /// A snap target rather than a rule — plenty of people drag them elsewhere.
    private let screenMargin: CGFloat = 30

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drag a rectangle over each desktop widget.")
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Model in, model out

    /// Take what is already in the config. Anything that is not a preset size
    /// becomes the nearest one about its own centre — which is the point of the
    /// overlay, and is visible on screen long before anything is saved.
    func adopt(_ widgets: [WidgetRect]) {
        let W = max(1, bounds.width), H = max(1, bounds.height)
        placed = widgets.map { w in
            let r = CGRect(x: CGFloat(w.x) * W, y: CGFloat(w.y) * H,
                           width: CGFloat(w.w) * W, height: CGFloat(w.h) * H)
            let size = DesktopWidgetSize.nearest(to: r.size)
            return clamped(WidgetPlacement(size: size,
                                           origin: CGPoint(x: r.midX - size.points.width / 2,
                                                           y: r.midY - size.points.height / 2)))
        }
        selection = nil
    }

    /// Screen fractions, ready for `Config.widgets`.
    var widgets: [WidgetRect] {
        let W = max(1, bounds.width), H = max(1, bounds.height)
        return placed.map {
            let r = $0.rect
            return WidgetRect(x: Float(r.minX / W), y: Float(r.minY / H),
                              w: Float(r.width / W), h: Float(r.height / H))
        }
    }

    var count: Int { placed.count }
    var hasSelection: Bool { selection != nil }

    func removeSelected() {
        guard let i = selection, i < placed.count else { return }
        placed.remove(at: i)
        selection = placed.isEmpty ? nil : min(i, placed.count - 1)
        Haptics.level()
        onChange?()
    }

    func removeAll() {
        guard !placed.isEmpty else { return }
        placed.removeAll()
        selection = nil
        Haptics.level()
        onChange?()
    }

    // MARK: - Drawing

    override func draw(_ dirty: NSRect) {
        // The wash, with a hole for every placement. Even-odd winding rather
        // than a `.clear` composite: it needs no assumption about whether this
        // view ended up layer-backed (the HUD's visual effect view backs the
        // whole hierarchy), and it is one fill either way.
        //
        // The holes are the reason this reads at a glance. A marked widget shows
        // through at full brightness against a dimmed desktop, so "did I get
        // that one" is answered by looking rather than by comparing numbers.
        let wash = NSBezierPath(rect: bounds)
        wash.windingRule = .evenOdd
        for p in placed { wash.append(NSBezierPath(roundedRect: p.rect, xRadius: 12, yRadius: 12)) }
        NSColor.black.withAlphaComponent(isPassive ? 0.22 : 0.44).setFill()
        wash.fill()

        drawGuides()

        for (i, p) in placed.enumerated() { draw(p, selected: i == selection) }

        if case .creating(let anchor, let current) = drag { drawCreation(anchor, current) }

        if placed.isEmpty, case .none = drag { drawEmptyHint() }
    }

    private func draw(_ p: WidgetPlacement, selected: Bool) {
        let r = p.rect
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        let accent = NSColor.controlAccentColor
        accent.withAlphaComponent(selected ? 0.22 : 0.12).setFill()
        path.fill()
        (selected ? accent : accent.withAlphaComponent(0.75)).setStroke()
        path.lineWidth = selected ? 3 : 2
        path.stroke()

        if selected { drawHandles(r) }

        let px = screen.map { p.size.pixels(on: $0) }
        let sub = px.map { String(format: "%.0f × %.0f px", $0.width, $0.height) }
            ?? String(format: "%.0f × %.0f pt", p.size.points.width, p.size.points.height)
        drawLabel("\(p.size.name)  ·  \(p.size.cells.across) × \(p.size.cells.down)",
                  sub: sub, in: r)
    }

    /// Corner pips. Not draggable — resizing is what the four presets replace —
    /// but they say "this one is selected" in the vocabulary a rectangle editor
    /// uses, and the arrow keys move whatever is wearing them.
    private func drawHandles(_ r: NSRect) {
        NSColor.controlAccentColor.setFill()
        for pt in [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
                   NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)] {
            let d = NSRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)
            NSBezierPath(ovalIn: d).fill()
        }
    }

    private func drawLabel(_ title: String, sub: String, in r: NSRect) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ]
        let t = NSAttributedString(string: title, attributes: titleAttrs)
        let s = NSAttributedString(string: sub, attributes: subAttrs)
        let ts = t.size(), ss = s.size()
        let w = max(ts.width, ss.width) + 18
        let h = ts.height + ss.height + 10
        // Centred, and never drawn outside the rectangle it belongs to — a small
        // widget is 155pt square and the pill has to live inside that.
        let pill = NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
        t.draw(at: NSPoint(x: pill.midX - ts.width / 2, y: pill.minY + 4))
        s.draw(at: NSPoint(x: pill.midX - ss.width / 2, y: pill.minY + 4 + ts.height))
    }

    /// The live rubber band: what the hand is doing, faintly, with the preset it
    /// has landed on drawn solidly over the top. Showing both is what teaches
    /// the snapping — the rectangle you are dragging is visibly not the
    /// rectangle you are going to get.
    private func drawCreation(_ anchor: CGPoint, _ current: CGPoint) {
        let raw = NSRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                         width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
        NSColor.white.withAlphaComponent(0.5).setStroke()
        let rawPath = NSBezierPath(rect: raw)
        rawPath.lineWidth = 1
        rawPath.setLineDash([4, 3], count: 2, phase: 0)
        rawPath.stroke()

        if let preview = pending { draw(preview, selected: true) }
    }

    private func drawEmptyHint() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
        ]
        let s = NSAttributedString(string: "Drag a rectangle over each of your widgets",
                                   attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
    }

    private func drawGuides() {
        guard !guides.isEmpty else { return }
        NSColor.systemPink.withAlphaComponent(0.9).setStroke()
        for g in guides {
            let p = NSBezierPath()
            if g.vertical {
                p.move(to: NSPoint(x: g.value, y: 0)); p.line(to: NSPoint(x: g.value, y: bounds.height))
            } else {
                p.move(to: NSPoint(x: 0, y: g.value)); p.line(to: NSPoint(x: bounds.width, y: g.value))
            }
            p.lineWidth = 1
            p.setLineDash([6, 4], count: 2, phase: 0)
            p.stroke()
        }
    }

    // MARK: - Geometry

    /// The placement a drag from `anchor` to `current` produces.
    ///
    /// The corner under the mouse when the button went down stays exactly where
    /// it is, and the snapped size grows away from it in whichever direction the
    /// drag went. Anchoring on the centre instead would make the rectangle creep
    /// out from under the pointer as the preset changed mid-drag.
    private func creation(anchor: CGPoint, current: CGPoint) -> WidgetPlacement {
        let drawn = CGSize(width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
        let size = DesktopWidgetSize.nearest(to: drawn)
        let p = size.points
        return WidgetPlacement(size: size,
                               origin: CGPoint(x: current.x >= anchor.x ? anchor.x : anchor.x - p.width,
                                               y: current.y >= anchor.y ? anchor.y : anchor.y - p.height))
    }

    /// Keep the whole rectangle on the screen. A placement half off the edge is
    /// one the user cannot grab again, and a widget cannot be there anyway.
    private func clamped(_ p: WidgetPlacement) -> WidgetPlacement {
        var q = p
        let s = p.size.points
        q.origin.x = min(max(0, q.origin.x), max(0, bounds.width - s.width))
        q.origin.y = min(max(0, q.origin.y), max(0, bounds.height - s.height))
        return q
    }

    private func hit(_ point: NSPoint) -> Int? {
        // Front-most first, so a widget dropped on top of another is the one you
        // get hold of.
        for i in placed.indices.reversed() where placed[i].rect.contains(point) { return i }
        return nil
    }

    // MARK: - Snapping

    /// Everything a moving edge is allowed to land on, along one axis.
    private func targets(vertical: Bool, excluding: Int?) -> [CGFloat] {
        let extent = vertical ? bounds.width : bounds.height
        var t: [CGFloat] = [screenMargin, extent / 2, extent - screenMargin]
        for (i, p) in placed.enumerated() where i != excluding {
            let r = p.rect
            let lo = vertical ? r.minX : r.minY
            let mid = vertical ? r.midX : r.midY
            let hi = vertical ? r.maxX : r.maxY
            // Edges and centres line widgets up in a column or a row; the two
            // gutter offsets let one sit immediately beside another at the
            // spacing macOS itself would have used.
            t.append(contentsOf: [lo, mid, hi,
                                  hi + DesktopWidgetSize.gutter,
                                  lo - DesktopWidgetSize.gutter])
        }
        return t
    }

    /// Pull the moving edges onto the nearest target and report the offset.
    private func snapOffset(_ values: [CGFloat], vertical: Bool, excluding: Int?,
                            into names: inout Set<String>) -> CGFloat {
        var best: (delta: CGFloat, target: CGFloat)?
        for v in values {
            for t in targets(vertical: vertical, excluding: excluding) {
                let d = t - v
                if abs(d) <= snapTolerance, best == nil || abs(d) < abs(best!.delta) { best = (d, t) }
            }
        }
        guard let b = best else { return 0 }
        names.insert("\(vertical ? "x" : "y"):\(Int(b.target.rounded()))")
        guides.append(Guide(vertical: vertical, value: b.target))
        return b.delta
    }

    /// Snap a placement's origin, buzzing once per newly caught line.
    ///
    /// `.alignment` on the transition IN and never per frame, the same rule and
    /// for the same reason as `DesktopGridView`: a drag parked on a guide should
    /// click once, not sixty times a second.
    private func snapped(_ p: WidgetPlacement, excluding: Int?) -> WidgetPlacement {
        guides.removeAll()
        var names: Set<String> = []
        let r = p.rect
        let dx = snapOffset([r.minX, r.midX, r.maxX], vertical: true,
                            excluding: excluding, into: &names)
        let dy = snapOffset([r.minY, r.midY, r.maxY], vertical: false,
                            excluding: excluding, into: &names)
        if !names.subtracting(engaged).isEmpty { Haptics.alignment() }
        engaged = names
        var q = p
        q.origin.x += dx
        q.origin.y += dy
        return q
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guides.removeAll(); engaged.removeAll(); pending = nil

        if let i = hit(p) {
            // A second click on a placed rectangle steps it round the four
            // sizes. It is the repair for the one case snapping gets wrong —
            // a rectangle drawn between two presets — and it beats deleting and
            // redrawing to change your mind.
            if event.clickCount == 2 {
                placed[i] = clamped(placed[i].resized(to: placed[i].size.next))
                selection = i
                Haptics.level()
                drag = .none
                return
            }
            selection = i
            drag = .moving(index: i, grab: CGSize(width: p.x - placed[i].origin.x,
                                                  height: p.y - placed[i].origin.y))
            return
        }
        selection = nil
        drag = .creating(anchor: p, current: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .creating(let anchor, _):
            drag = .creating(anchor: anchor, current: p)
            // Below the threshold this is still a click on its way to being a
            // click, so there is nothing to preview and nothing to buzz about.
            let small = abs(p.x - anchor.x) < minDrag && abs(p.y - anchor.y) < minDrag
            guides.removeAll()
            pending = small ? nil
                : clamped(snapped(clamped(creation(anchor: anchor, current: p)), excluding: nil))
        case .moving(let i, let grab):
            guard i < placed.count else { return }
            var q = placed[i]
            q.origin = CGPoint(x: p.x - grab.width, y: p.y - grab.height)
            placed[i] = clamped(snapped(q, excluding: i))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .none:
            break
        case .creating:
            // No pending placement means the drag never got past the threshold:
            // a click, and the user was dismissing the selection.
            guard let made = pending else { break }
            placed.append(made)
            selection = placed.count - 1
            Haptics.level()
            onChange?()
        case .moving:
            break
        }
        drag = .none
        pending = nil
        guides.removeAll()
        engaged.removeAll()
        needsDisplay = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Three speeds, matching the Elements grid: ⌥ a point at a time for the
        // last hair of alignment, plain a few, ⇧ a stride.
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 20
                          : event.modifierFlags.contains(.option) ? 1 : 5
        var handled = true
        switch event.keyCode {
        case 123: nudge(dx: -step, dy: 0)
        case 124: nudge(dx: step, dy: 0)
        case 125: nudge(dx: 0, dy: step)
        case 126: nudge(dx: 0, dy: -step)
        case 51, 117: removeSelected()                 // delete / forward delete
        case 48: cycleSelection()                      // tab
        case 49: cycleSize()                           // space
        default: handled = false
        }
        if !handled { super.keyDown(with: event) }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard let i = selection, i < placed.count else { return }
        var q = placed[i]
        q.origin.x += dx
        q.origin.y += dy
        placed[i] = clamped(q)
        guides.removeAll()
        needsDisplay = true
    }

    private func cycleSelection() {
        guard !placed.isEmpty else { return }
        selection = selection.map { ($0 + 1) % placed.count } ?? 0
        Haptics.alignment()
    }

    private func cycleSize() {
        guard let i = selection, i < placed.count else { return }
        placed[i] = clamped(placed[i].resized(to: placed[i].size.next))
        Haptics.level()
    }
}

// MARK: - The window

/// A full-screen sheet of glass you place widgets on.
///
/// One at a time, held by a static reference for as long as it is on screen: the
/// caller gets a completion and nothing to retain, and there is no way to end up
/// with two overlays fighting over the same config.
final class WidgetSetupOverlay: NSObject, NSWindowDelegate {

    private static var current: WidgetSetupOverlay?

    /// Whether one is up. The pane uses this to avoid stacking a second.
    static var isPresented: Bool { current != nil }

    private let window: NSWindow
    private let canvas: WidgetSetupCanvas
    private let completion: ([WidgetRect]?) -> Void
    private let countLabel = NSTextField(labelWithString: "")
    private let hud = NSVisualEffectView()
    private var finished = false

    /// Put the overlay up. `completion` gets the placements as screen fractions
    /// on Save and nil on Cancel — nil meaning "change nothing", not "no
    /// widgets", which is what makes Cancel safe.
    ///
    /// One screen: `Config.widgets` are fractions with no display attached, so
    /// they are applied to every screen the app draws on (the same property that
    /// makes `Config.dockRect` dangerous to write speculatively). Marking them on
    /// the main display and letting them scale is the honest reading of what is
    /// stored; a per-display version needs a per-display config first.
    static func present(screen: NSScreen? = nil,
                        widgets: [WidgetRect],
                        completion: @escaping ([WidgetRect]?) -> Void) {
        guard current == nil, let target = screen ?? NSScreen.main else {
            completion(nil)
            return
        }
        current = WidgetSetupOverlay(screen: target, widgets: widgets, completion: completion)
    }

    private init(screen: NSScreen, widgets: [WidgetRect],
                 completion: @escaping ([WidgetRect]?) -> Void) {
        self.completion = completion
        canvas = WidgetSetupCanvas(screen: screen)

        window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
        // Above ordinary windows so it is unambiguously in front of whatever was
        // on the desktop, and below `.mainMenu` so the menu bar — the only way
        // back into an LSUIElement app once clicks are passing through — stays
        // visible and clickable. See the header.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.title = "Widget Setup"
        window.setAccessibilityLabel("Widget setup overlay")

        super.init()

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.autoresizingMask = [.width, .height]
        canvas.onChange = { [weak self] in self?.refreshCount() }
        root.addSubview(canvas)
        buildHUD(into: root, screen: screen)
        window.contentView = root
        window.delegate = self
        window.initialFirstResponder = canvas

        canvas.adopt(widgets)
        refreshCount()

        // Activation, not key-window changes, decides click-through: moving key
        // to another window OF OURS is not the user reaching past the overlay.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appActivated),
                       name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDeactivated),
                       name: NSApplication.didResignActiveNotification, object: nil)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - HUD

    private func buildHUD(into root: NSView, screen: NSScreen) {
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 14
        hud.layer?.masksToBounds = true
        hud.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Where are your widgets?")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let hint = NSTextField(wrappingLabelWithString:
            "Drag a rectangle over each one — it snaps to the nearest real widget size. Drag a "
          + "placed rectangle to move it, double-click or press Space to change its size, ⌫ to "
          + "remove it. Click any other app and this sheet lets your clicks through; come back "
          + "with the Elemental menu bar icon.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 460
        // Fixed rather than intrinsic, so the panel is one stable width and the
        // button row below can be tied to it without the two fighting.
        hint.widthAnchor.constraint(equalToConstant: 460).isActive = true

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor

        let clear = NSButton(title: "Clear All", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [countLabel, spacer, clear, cancel, save])
        buttons.spacing = 8
        buttons.alignment = .centerY

        let column = NSStackView(views: [title, hint, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false

        hud.addSubview(column)
        root.addSubview(hud)

        // Sat above the dock rather than at the bottom of the screen, using the
        // same inset the dock reports — a panel half behind the dock is a panel
        // with an unclickable Save button.
        let dockInset = max(0, screen.visibleFrame.minY - screen.frame.minY)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: hud.topAnchor),
            column.leadingAnchor.constraint(equalTo: hud.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: hud.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: hud.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: hint.widthAnchor),
            hud.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                        constant: -(dockInset + 24)),
        ])
    }

    private func refreshCount() {
        let n = canvas.count
        countLabel.stringValue = n == 0 ? "Nothing placed yet"
                                        : "\(n) widget\(n == 1 ? "" : "s") placed"
    }

    // MARK: - Click-through

    @objc private func appActivated() {
        window.ignoresMouseEvents = false
        canvas.isPassive = false
        hud.alphaValue = 1
        guard !finished else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    @objc private func appDeactivated() {
        window.ignoresMouseEvents = true
        canvas.isPassive = true
        // Faded rather than hidden: the overlay is still holding unsaved work,
        // and a panel that vanished would read as the setup having been closed.
        hud.alphaValue = 0.45
    }

    // MARK: - Finishing

    @objc private func save() { finish(canvas.widgets) }
    @objc private func cancel() { finish(nil) }

    @objc private func clearAll() { canvas.removeAll() }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ result: [WidgetRect]?) {
        guard !finished else { return }
        finished = true
        NotificationCenter.default.removeObserver(self)
        window.delegate = nil
        window.orderOut(nil)
        // `current` is the only strong reference to this object, so clearing it
        // can deallocate self — potentially before the completion has run, since
        // a method does not retain its own receiver. Hand the closure out to a
        // local first and hold self across the call.
        let hand = completion
        WidgetSetupOverlay.current = nil
        withExtendedLifetime(self) { hand(result) }
    }
}

/// Borderless windows cannot become key by default, and AppKit will shrink one
/// that covers the menu bar to the visible frame unless it is told not to.
/// Both would be silent: the overlay would take no keystrokes, and it would sit
/// a menu-bar's-height short of the top with every placement offset to match.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
