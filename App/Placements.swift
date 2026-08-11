//  Placements.swift — the one model behind where your desktop furniture is.
//
//  There were two placement editors. A 320pt miniature pinned to the top of the
//  Elements pane, with a 700pt copy of itself on a sheet behind an "Edit at Full
//  Size…" button, working on free rectangles; and a full-screen translucent
//  overlay over the real desktop, working on a size PRESET plus an origin. Two
//  models, two sets of snapping rules, two commit paths, two answers to "how big
//  is a widget" — and the user was right to call that a bug rather than a
//  choice. A rectangle dragged in one of them could not be expressed in the
//  other.
//
//  So there is one model now, and it lives here. Both surfaces are views ONTO
//  it: the miniature in the pane is a live map of the same placements the
//  overlay is editing, they update each other while a drag is in flight, and
//  there is exactly one path from a finished gesture to `Config`.
//
//  ---- What a placement is
//
//  Fractions of the screen with y counting DOWN, which is the convention
//  `WidgetRect`, `Furniture` and the simulation already share, so saving is a
//  divide and nothing else.
//
//  A widget is never a free rectangle. macOS has exactly four desktop widget
//  sizes, they are fixed numbers of POINTS on every Mac, and the system lays
//  them out on a grid — so the user supplies the position, which they know and
//  we cannot, and the preset supplies the size, which they do not know and we
//  can. `WidgetPlacement` holds a preset and a centre; a non-preset widget
//  cannot be expressed. The dock is the other way round: its thickness comes
//  from `NSScreen.visibleFrame` exactly and its EXTENT is a guess made from
//  com.apple.dock that is known to come up short, so it stays a free rectangle
//  the user can pull to the right length.
//
//  ---- Why nothing new is stored
//
//  `Config.widgets` is still a list of plain fractional rectangles and
//  `Config.init(from:)` is untouched — which matters, because it is hand-rolled
//  and a field added to the struct and forgotten there decodes as its default
//  forever. The preset is not persisted because it does not need to be: a
//  fraction that came out of a preset classifies straight back to that preset on
//  the way in, so the round trip is lossless without a schema change.

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

    /// The corner radius the real widget is drawn with, in points.
    ///
    /// macOS does not publish this and it is not one number: the rounding grows
    /// with the container, the way it does everywhere else in the system. These
    /// are read off the four sizes on screen and are deliberately generous,
    /// because the failure that reads as WRONG is a square corner on a
    /// wireframe sitting over a very round widget, not a radius three points
    /// out. Anything that draws a placement gets its radius from here, so the
    /// miniature and the overlay cannot disagree about it.
    var cornerRadius: CGFloat {
        switch self {
        case .small:      return 21
        case .medium:     return 22
        case .large:      return 26
        case .extraLarge: return 30
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

    /// How far in from the screen edge macOS parks the outermost widget column,
    /// in points. A snap target rather than a rule — plenty of people drag them
    /// elsewhere.
    static let screenMargin: CGFloat = 30

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

// MARK: - Corner geometry

/// A rounded rectangle with CONTINUOUS corners — the squircle macOS rounds its
/// containers with, rather than AppKit's quarter circle.
///
/// This matters here more than it usually would. A widget's radius is close to a
/// fifth of its short side, and at that proportion the curvature step where a
/// circular arc meets the straight edge is plainly visible: the wireframe
/// pinches at each corner and the real widget behind it does not, which is
/// exactly the mismatch these editors exist to remove.
///
/// One cubic per corner. The curve leaves the straight edge at `d = 1.5r` from
/// the corner rather than at `r`, which is what spreads the bend along the edge,
/// and the control points sit at `0.195 d` from the corner. That second number
/// is solved rather than guessed: a cubic with symmetric control points at
/// distance `c` from the corner passes through a point √2(d + 3c)/8 away from
/// it, and 0.195 is the value that puts that point back where a circle of radius
/// `r` would have put it, at 0.414 r. So the corner is as DEEP as a circular one
/// and reaches further along the edge, which is the whole character of a
/// continuous corner.
func continuousRoundedRect(_ r: NSRect, radius: CGFloat) -> NSBezierPath {
    let limit = min(r.width, r.height) / 2
    let d = min(max(0, radius) * 1.5, max(0, limit))
    guard d > 0.05 else { return NSBezierPath(rect: r) }
    let c = d * 0.195
    let p = NSBezierPath()
    let x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY

    p.move(to: NSPoint(x: x0 + d, y: y0))
    p.line(to: NSPoint(x: x1 - d, y: y0))
    p.curve(to: NSPoint(x: x1, y: y0 + d),
            controlPoint1: NSPoint(x: x1 - c, y: y0),
            controlPoint2: NSPoint(x: x1, y: y0 + c))
    p.line(to: NSPoint(x: x1, y: y1 - d))
    p.curve(to: NSPoint(x: x1 - d, y: y1),
            controlPoint1: NSPoint(x: x1, y: y1 - c),
            controlPoint2: NSPoint(x: x1 - c, y: y1))
    p.line(to: NSPoint(x: x0 + d, y: y1))
    p.curve(to: NSPoint(x: x0, y: y1 - d),
            controlPoint1: NSPoint(x: x0 + c, y: y1),
            controlPoint2: NSPoint(x: x0, y: y1 - c))
    p.line(to: NSPoint(x: x0, y: y0 + d))
    p.curve(to: NSPoint(x: x0 + d, y: y0),
            controlPoint1: NSPoint(x: x0, y: y0 + c),
            controlPoint2: NSPoint(x: x0 + c, y: y0))
    p.close()
    return p
}

// MARK: - One widget

/// A placed widget: a preset, and where its CENTRE is as a fraction of the
/// screen with y down.
///
/// Centre rather than a corner on purpose. Every operation that changes the
/// preset — the double-click cycle, adopting a detector's rectangle, pressing
/// Space — should leave the widget looking like it is still where it was, and
/// that is only true if the fixed point is the middle.
struct WidgetPlacement: Equatable {
    var size: DesktopWidgetSize
    var centre: CGPoint
}

// MARK: - The model

/// Where everything on the desktop is, and who is currently touching it.
///
/// One instance is owned by the Elements pane and handed to every view that
/// edits placements. Views do not own geometry; they read it, write it back
/// through the mutators here, and redraw when told. That is what makes the
/// miniature and the full-screen overlay the same feature rather than two
/// features that agree most of the time.
final class PlacementModel {

    /// Something the user can take hold of. The menu bar is deliberately not in
    /// here: its geometry belongs to macOS and only its switch is ours.
    enum Ref: Equatable { case dock, widget(Int) }

    /// What just happened, so an observer can do the cheap thing for a redraw
    /// and the expensive thing only on a finished gesture.
    enum Change {
        /// A rectangle moved. Fires on every frame of a drag — redraw only.
        case geometry
        /// The selection moved between elements.
        case selection
        /// A drag started or ended. This is what drives the live highlight of
        /// the same element in the OTHER view.
        case dragging
        /// A gesture finished. This is the one place a config is written.
        case commit
    }

    // MARK: Reference screen

    /// The screen the presets are measured against, in POINTS.
    ///
    /// A widget is 155 or 329 or 677 points wide on every Mac, so a preset is a
    /// fixed fraction of a screen only once you know how many points wide that
    /// screen is. Everything stored below is a fraction, because that is what
    /// `Config` holds and what survives a resolution change; this is the
    /// constant that converts between the two.
    var screenPoints: CGSize {
        didSet { if screenPoints != oldValue { notify(.geometry) } }
    }

    /// The shape of that screen, for the miniature. Read from the display rather
    /// than assumed, so the little screen is the user's screen.
    var aspect: CGFloat { screenPoints.width / max(1, screenPoints.height) }

    // MARK: Geometry, all fractions with y down

    private(set) var widgets: [WidgetPlacement] = []

    /// The dock. Nil means "no dock found or configured".
    var dock: CGRect? { didSet { if dock != oldValue { notify(.geometry) } } }

    /// Menu bar height as a fraction of the screen, 0 for none.
    var menuBarHeight: CGFloat = 0.025 {
        didSet { if menuBarHeight != oldValue { notify(.geometry) } }
    }

    // MARK: Styling, shared so both views light up identically

    var wetDock = true { didSet { notify(.geometry) } }
    var wetWidgets = true { didSet { notify(.geometry) } }
    var wetMenuBar = false { didSet { notify(.geometry) } }
    /// 0...1, dims the lit-up styling the way the strength slider dims the effect.
    var strength: CGFloat = 1 { didSet { notify(.geometry) } }
    /// A faint copy of the user's screenshot, behind the rectangles in the
    /// miniature. The overlay does not need one — it is over the real thing.
    var backdrop: NSImage? { didSet { notify(.geometry) } }

    // MARK: Who is touching what

    var selection: Ref? { didSet { if selection != oldValue { notify(.selection) } } }

    /// The element under the hand RIGHT NOW, in whichever view has hold of it.
    ///
    /// Set by the view that owns the gesture and read by every view, which is
    /// the whole of the live two-way highlight: drag a widget on the miniature
    /// and the same widget lights up on the full-screen overlay, and the other
    /// way round. Nil the moment the button comes up.
    var dragging: Ref? { didSet { if dragging != oldValue { notify(.dragging) } } }

    init(screenPoints: CGSize? = nil) {
        if let s = screenPoints, s.width > 1, s.height > 1 {
            self.screenPoints = s
        } else if let s = NSScreen.main, s.frame.width > 1, s.frame.height > 1 {
            self.screenPoints = s.frame.size
        } else {
            self.screenPoints = CGSize(width: 1440, height: 900)
        }
    }

    // MARK: - Observers
    //
    // A tiny multicast rather than KVO or Combine: three or four listeners, all
    // of them views or view controllers that already have a lifetime, and each
    // one wants a plain "redraw" or "write the config". Owners are held by
    // identity and drop themselves in `deinit`, so nothing here keeps a view
    // alive.

    private var observers: [(owner: ObjectIdentifier, body: (Change) -> Void)] = []

    func observe(_ owner: AnyObject, _ body: @escaping (Change) -> Void) {
        observers.append((ObjectIdentifier(owner), body))
    }

    func stopObserving(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        observers.removeAll { $0.owner == id }
    }

    private func notify(_ change: Change) {
        // Iterating the array copies it, so an observer that adds or removes one
        // while responding cannot corrupt the walk.
        for o in observers { o.body(change) }
    }

    /// A gesture finished. The single path from an edit to `Config` — every
    /// editor calls this on mouse-up and nowhere else, because a commit
    /// re-syncs every other pane and pushes new collision geometry into the
    /// live wallpaper, which is not something to do sixty times a second.
    func commit() { notify(.commit) }

    // MARK: - Widgets

    func setWidgets(_ w: [WidgetPlacement]) {
        widgets = w
        clampSelection()
        notify(.geometry)
    }

    func setWidget(_ p: WidgetPlacement, at i: Int) {
        guard i >= 0, i < widgets.count, widgets[i] != p else { return }
        widgets[i] = p
        notify(.geometry)
    }

    /// Append and select. Returns the new index.
    @discardableResult
    func addWidget(_ p: WidgetPlacement) -> Int {
        widgets.append(p)
        notify(.geometry)
        selection = .widget(widgets.count - 1)
        return widgets.count - 1
    }

    func removeWidget(at i: Int) {
        guard i >= 0, i < widgets.count else { return }
        widgets.remove(at: i)
        selection = widgets.isEmpty ? nil : .widget(min(i, widgets.count - 1))
        notify(.geometry)
    }

    func removeAllWidgets() {
        guard !widgets.isEmpty else { return }
        widgets.removeAll()
        selection = nil
        notify(.geometry)
    }

    /// Step a widget round the four sizes about its own centre.
    func cycleSize(_ i: Int) {
        guard i >= 0, i < widgets.count else { return }
        var p = widgets[i]
        p.size = p.size.next
        widgets[i] = clamped(p)
        notify(.geometry)
    }

    private func clampSelection() {
        if case .widget(let i) = selection, i >= widgets.count {
            selection = widgets.isEmpty ? nil : .widget(widgets.count - 1)
        }
    }

    // MARK: - Config bridge

    /// The placements as `Config.widgets` wants them.
    var widgetRects: [WidgetRect] {
        widgets.map { p in
            let r = rect(of: p)
            return WidgetRect(x: Float(r.minX), y: Float(r.minY),
                              w: Float(r.width), h: Float(r.height))
        }
    }

    /// Take fractional rectangles from anywhere — the config, the screenshot
    /// detector — and make them placements.
    ///
    /// Every one is classified to the nearest preset about its own centre. That
    /// is the point of the preset model and it is visible on screen long before
    /// anything is saved: open either editor over detector output and watch six
    /// approximately-widget-shaped boxes become six actual widgets.
    func setWidgetRects(_ rects: [WidgetRect]) {
        setWidgets(rects.map { placement(fromFraction:
            CGRect(x: CGFloat($0.x), y: CGFloat($0.y),
                   width: CGFloat($0.w), height: CGFloat($0.h))) })
    }

    /// One fractional rectangle, classified and centred.
    func placement(fromFraction r: CGRect) -> WidgetPlacement {
        let inPoints = CGSize(width: r.width * screenPoints.width,
                              height: r.height * screenPoints.height)
        return clamped(WidgetPlacement(size: .nearest(to: inPoints),
                                       centre: CGPoint(x: r.midX, y: r.midY)))
    }

    // MARK: - Rectangles

    /// A preset's size as a fraction of the reference screen.
    func fractionalSize(_ s: DesktopWidgetSize) -> CGSize {
        CGSize(width: s.points.width / max(1, screenPoints.width),
               height: s.points.height / max(1, screenPoints.height))
    }

    func rect(of p: WidgetPlacement) -> CGRect {
        let s = fractionalSize(p.size)
        return CGRect(x: p.centre.x - s.width / 2, y: p.centre.y - s.height / 2,
                      width: s.width, height: s.height)
    }

    func rect(of ref: Ref) -> CGRect? {
        switch ref {
        case .dock: return dock
        case .widget(let i):
            guard i >= 0, i < widgets.count else { return nil }
            return rect(of: widgets[i])
        }
    }

    /// Keep a widget entirely on the screen. One that is half off the edge
    /// cannot be grabbed again, and a real widget cannot be there anyway.
    func clamped(_ p: WidgetPlacement) -> WidgetPlacement {
        let s = fractionalSize(p.size)
        var q = p
        q.centre.x = min(max(s.width / 2, q.centre.x), max(s.width / 2, 1 - s.width / 2))
        q.centre.y = min(max(s.height / 2, q.centre.y), max(s.height / 2, 1 - s.height / 2))
        return q
    }

    /// The same for a free rectangle — the dock.
    func clamped(_ r: CGRect) -> CGRect {
        var q = r
        q.origin.x = min(max(0, q.origin.x), max(0, 1 - q.width))
        q.origin.y = min(max(0, q.origin.y), max(0, 1 - q.height))
        return q
    }

    /// Write a rectangle back to whatever it belongs to.
    ///
    /// A widget keeps its preset and takes the rectangle's CENTRE, so a move
    /// cannot smuggle in a size that macOS would never draw. Only the dock is
    /// free, because only the dock's extent is genuinely unknown.
    func write(_ r: CGRect, to ref: Ref) {
        switch ref {
        case .dock:
            dock = r
        case .widget(let i):
            guard i >= 0, i < widgets.count else { return }
            setWidget(clamped(WidgetPlacement(size: widgets[i].size,
                                              centre: CGPoint(x: r.midX, y: r.midY))), at: i)
        }
    }

    // MARK: - Elements
    //
    // The flat list both views draw from, back to front. Having one list means
    // the miniature and the overlay cannot end up drawing different things, or
    // drawing the same thing two different shapes.

    struct Element {
        /// Nil for the menu bar, which is drawn and never edited.
        var ref: Ref?
        /// Fractions, y down.
        var rect: CGRect
        var label: String
        /// Whether weather is allowed to mark it, for the lit-up styling.
        var wet: Bool
        /// The corner rounding of the REAL thing, in points on the reference
        /// screen. Views scale it by however big they are drawing that screen.
        var radiusPoints: CGFloat
        var editable: Bool
    }

    var elements: [Element] {
        var out: [Element] = []
        if menuBarHeight > 0.001 {
            out.append(Element(ref: nil,
                               rect: CGRect(x: 0, y: 0, width: 1, height: menuBarHeight),
                               label: "Menu bar", wet: wetMenuBar,
                               radiusPoints: 0, editable: false))
        }
        if let d = dock {
            // The dock is a slab with a very round end. Half its thickness caps
            // the radius, so a thin dock reads as a pill and a fat one as a
            // rounded slab, which is what the real one does.
            let thickness = min(d.height * screenPoints.height, d.width * screenPoints.width)
            out.append(Element(ref: .dock, rect: d, label: "Dock", wet: wetDock,
                               radiusPoints: min(18, thickness / 2), editable: true))
        }
        for (i, w) in widgets.enumerated() {
            out.append(Element(ref: .widget(i), rect: rect(of: w),
                               label: "Widget \(i + 1)", wet: wetWidgets,
                               radiusPoints: w.size.cornerRadius, editable: true))
        }
        return out
    }

    /// The front-most editable element under a fractional point.
    func hit(_ p: CGPoint) -> Ref? {
        for e in elements.reversed() where e.editable && e.rect.contains(p) { return e.ref }
        return nil
    }

    /// Editable elements in a stable order, for Tab.
    var cycleOrder: [Ref] { elements.compactMap { $0.editable ? $0.ref : nil } }

    // MARK: - Snapping
    //
    // One set of rules, in fractions, used by every editor. The tolerance comes
    // from the caller as a fraction of the screen, because "close enough to
    // catch" is a fixed distance under the HAND and the two views draw the same
    // screen at very different scales.

    struct Guide: Equatable { var vertical: Bool; var value: CGFloat }

    /// A snapped rectangle, the lines it caught, and their names.
    ///
    /// The names are what the haptic is fired from. `.alignment` belongs on the
    /// TRANSITION into a snap and never per frame — a drag parked on a guide
    /// should click once, not sixty times a second — so the caller diffs this
    /// set against the one it was holding.
    struct Snap {
        var rect: CGRect
        var guides: [Guide] = []
        var names: Set<String> = []
    }

    /// Everything a moving edge is allowed to land on, along one axis.
    ///
    /// The screen's edges, its centre and the margin macOS parks the outer
    /// widget column at; every other element's edges and centre; and the two
    /// gutter offsets, which put a widget exactly beside another at the spacing
    /// the system itself would have used. The old miniature also snapped to a
    /// twelfth-of-a-screen grid, which was a reasonable idea for free
    /// rectangles and is noise now that a widget's size is a preset — it fights
    /// the gutter, which is the spacing that is actually real.
    func snapTargets(vertical: Bool, excluding: Ref?) -> [CGFloat] {
        let extent = vertical ? screenPoints.width : screenPoints.height
        let margin = DesktopWidgetSize.screenMargin / max(1, extent)
        let gutter = DesktopWidgetSize.gutter / max(1, extent)
        var t: [CGFloat] = [0, margin, 0.5, 1 - margin, 1]
        for e in elements where e.ref != excluding {
            let r = e.rect
            let lo = vertical ? r.minX : r.minY
            let mid = vertical ? r.midX : r.midY
            let hi = vertical ? r.maxX : r.maxY
            t.append(contentsOf: [lo, mid, hi, hi + gutter, lo - gutter])
        }
        return t
    }

    /// Pull the whole rectangle onto the nearest guide on each axis.
    func snapping(_ r: CGRect, moving: Ref?, tolerance: CGSize) -> Snap {
        var out = Snap(rect: r)
        let dx = snapOffset([r.minX, r.midX, r.maxX], vertical: true,
                            excluding: moving, tolerance: tolerance.width, into: &out)
        let dy = snapOffset([r.minY, r.midY, r.maxY], vertical: false,
                            excluding: moving, tolerance: tolerance.height, into: &out)
        out.rect = r.offsetBy(dx: dx, dy: dy)
        return out
    }

    /// Snap ONE edge, leaving the opposite edge exactly where it is.
    ///
    /// Resizing cannot go through `snapping`: offsetting the whole rectangle to
    /// bring the dragged edge onto a guide drags the anchored edge off wherever
    /// the user put it, so the box slides instead of growing.
    func snappingEdge(_ v: CGFloat, vertical: Bool, moving: Ref?,
                      tolerance: CGFloat, into snap: inout Snap) -> CGFloat {
        var best: CGFloat?
        for t in snapTargets(vertical: vertical, excluding: moving)
        where abs(t - v) <= tolerance && (best == nil || abs(t - v) < abs(best! - v)) {
            best = t
        }
        guard let b = best else { return v }
        snap.names.insert(name(b, vertical: vertical))
        snap.guides.append(Guide(vertical: vertical, value: b))
        return b
    }

    private func snapOffset(_ values: [CGFloat], vertical: Bool, excluding: Ref?,
                            tolerance: CGFloat, into snap: inout Snap) -> CGFloat {
        var best: (delta: CGFloat, target: CGFloat)?
        for v in values {
            for t in snapTargets(vertical: vertical, excluding: excluding) {
                let d = t - v
                if abs(d) <= tolerance, best == nil || abs(d) < abs(best!.delta) { best = (d, t) }
            }
        }
        guard let b = best else { return 0 }
        snap.names.insert(name(b.target, vertical: vertical))
        snap.guides.append(Guide(vertical: vertical, value: b.target))
        return b.delta
    }

    /// A guide's identity, coarse enough that a line caught on two successive
    /// frames is recognised as the same line.
    private func name(_ target: CGFloat, vertical: Bool) -> String {
        "\(vertical ? "x" : "y"):\(Int((target * 2000).rounded()))"
    }

    // MARK: - Describing what is selected

    /// The status line both editors show. One sentence, one wording.
    var selectionDescription: String {
        guard let ref = selection, let r = rect(of: ref) else {
            return widgets.isEmpty && dock == nil
                ? "Nothing placed yet — drag a rectangle over each widget."
                : "Click a rectangle to select it. Drag to move it, Space to change its size, "
                + "⌫ to remove it."
        }
        switch ref {
        case .dock:
            return String(format: "Dock — x %.0f%%, y %.0f%%, %.0f%% × %.0f%% of the screen",
                          r.minX * 100, r.minY * 100, r.width * 100, r.height * 100)
        case .widget(let i):
            guard i < widgets.count else { return "" }
            let s = widgets[i].size
            return String(format: "Widget %d — %@, %d × %d cells, %.0f × %.0f pt, at x %.0f%%, y %.0f%%",
                          i + 1, s.name, s.cells.across, s.cells.down,
                          s.points.width, s.points.height, r.minX * 100, r.minY * 100)
        }
    }
}
