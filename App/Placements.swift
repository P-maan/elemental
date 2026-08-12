//  Placements.swift — the one model behind where your desktop furniture is.
//
//  There were two placement editors. A 320pt miniature pinned to the top of the
//  Elements pane, with a 700pt copy of itself on a sheet behind an "Edit at Full
//  Size…" button; and a full-screen translucent overlay over the real desktop.
//  Two models, two sets of snapping rules, two commit paths, two answers to "how
//  big is a widget" — and the user was right to call that a bug rather than a
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
//  A widget is a free rectangle with four very strong magnets on it. macOS has
//  exactly four desktop widget sizes and they are fixed numbers of POINTS on
//  every Mac, so a drag that passes near one of them lands on it exactly — but
//  it is a magnet and not a cage, because the four sizes are what the SYSTEM
//  offers and this is a description of what is actually on the user's screen.
//  A stacked pair, a widget from an app that draws its own frame, or simply a
//  measurement the user trusts more than ours all have to be expressible. The
//  preset is therefore RECOVERED from the rectangle rather than stored with it
//  (`preset(of:)`), which is also what keeps `Config` unchanged.
//
//  The dock is free too, and for a different reason: its thickness comes from
//  `NSScreen.visibleFrame` exactly and its EXTENT is a guess made from
//  com.apple.dock that measures about a quarter short. `derivedDock` keeps that
//  guess as a snap target so the user can nudge away from the automatic answer
//  rather than from nothing.
//
//  ---- Suggestions
//
//  `FurnitureDetector` finds roughly half the widgets, invents a couple and cuts
//  the dock short. That is not good enough to write into a config and is far too
//  useful to throw away, so it lands in `suggestions`: a provisional layer,
//  drawn dashed, that the user accepts or dismisses one at a time. A suggestion
//  NEVER overwrites something the user placed — `setSuggestions` drops any that
//  lands on existing work before it is ever shown.
//
//  ---- Why nothing new is stored
//
//  `Config.widgets` is still a list of plain fractional rectangles and
//  `Config.init(from:)` is untouched — which matters, because it is hand-rolled
//  and a field added to the struct and forgotten there decodes as its default
//  forever.

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

    /// Every width and every height a preset can have, in points, deduplicated.
    /// These are the magnets a RESIZE drag catches on: one axis at a time, so
    /// pulling a small widget out sideways passes through 329 on its way to 677
    /// whatever its height is doing.
    static let presetWidths: [CGFloat] = [155, 329, 677]
    static let presetHeights: [CGFloat] = [155, 345]

    /// How near a resize has to come, in points, before a preset dimension takes
    /// it. Generous: these four sizes are what macOS actually draws, so landing
    /// on one is nearly always what was meant.
    static let magnet: CGFloat = 12

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

    /// The preset this size IS, or nil if it is a size of the user's own.
    ///
    /// A point and a half either way: a fraction stored in the config and
    /// multiplied back out by a screen dimension does not always land on the
    /// integer it came from, and a widget that read as "Custom, 329 × 155"
    /// after a relaunch would be a bug in the readout rather than in the
    /// placement.
    static func exact(_ size: CGSize, tolerance: CGFloat = 1.5) -> DesktopWidgetSize? {
        for candidate in allCases where abs(size.width - candidate.points.width) <= tolerance
            && abs(size.height - candidate.points.height) <= tolerance {
            return candidate
        }
        return nil
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

/// A placed widget. Fractions of the screen, y down.
///
/// A struct rather than a bare `CGRect` because a placement is a thing with a
/// life of its own — it gets snapped, described, classified — and because the
/// snapshot the overlay's Cancel restores wants a stable type.
struct WidgetPlacement: Equatable {
    var rect: CGRect

    /// How wet this one is allowed to get, 0 dry to 1 fully.
    ///
    /// Per-element rather than global because the widgets on a desk are not
    /// interchangeable: a clock you read at a glance wants to stay legible, and
    /// a photo widget is the one you actually want water running down. The
    /// global switch could only ever say "widgets, all of them, yes or no".
    var wetness: Float = 1

    init(rect: CGRect, wetness: Float = 1) {
        self.rect = rect
        self.wetness = wetness
    }

    /// Ordered so call sites that build the rect inline stay readable.
    init(wetnessFromConfig w: Float, rect: CGRect) {
        self.rect = rect
        self.wetness = w
    }
}

// MARK: - Handles
//
// One numbering for every editor and every rectangle: eight positions round the
// box, and each one owns a known set of edges. `handleEdges` is the single
// source of that mapping, so the miniature, the overlay and the resize solver
// cannot end up disagreeing about which way a corner grows.

enum ResizeHandle {

    /// The eight, in the order both views draw and index them.
    static let all: [Int] = Array(0...7)

    /// The four mid-edge ones.
    ///
    /// What the dock gets, on purpose. Every dock drag then changes exactly one
    /// edge, which is what "precise" means for a thing whose thickness is
    /// already known exactly and whose length is the only unknown — a corner
    /// grip would let a stray vertical wobble change a measurement the user was
    /// not trying to change.
    static let edges: [Int] = [1, 3, 4, 6]

    /// Which edges a handle moves.
    static func edges(_ i: Int) -> (left: Bool, right: Bool, top: Bool, bottom: Bool) {
        // 0,3,5 are the left column; 0,1,2 the top row; and so on round the
        // eight. No handle moves both edges of one axis, which is what makes
        // "keep the opposite edge pinned" true by construction.
        (left: i == 0 || i == 3 || i == 5,
         right: i == 2 || i == 4 || i == 7,
         top: i <= 2,
         bottom: i >= 5)
    }

    /// Where a handle sits on a rectangle, in whatever units the rectangle is.
    static func point(_ i: Int, in r: CGRect) -> CGPoint {
        let e = edges(i)
        return CGPoint(x: e.left ? r.minX : e.right ? r.maxX : r.midX,
                       y: e.top ? r.minY : e.bottom ? r.maxY : r.midY)
    }
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
        /// The suggestion layer changed: detection landed, or one was taken.
        case suggestions
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

    /// What `Furniture.desktop` works the dock out to be, from the screen's
    /// insets and com.apple.dock. Not a placement — a SNAP TARGET, so a user
    /// correcting the automatic answer starts from it rather than from nothing,
    /// and can put it back by dragging an edge until it catches.
    var derivedDock: CGRect? { didSet { if derivedDock != oldValue { notify(.geometry) } } }

    /// Whether the dock rectangle is the user's measurement rather than the
    /// derived guess. A suggestion is never allowed to overwrite it once it is.
    var dockIsUserPlaced = false

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

    /// Step a widget round the four presets about its own centre. Still here
    /// alongside free resizing, because "make this one exactly a medium" is a
    /// thing you want to say in one keystroke rather than by dragging until the
    /// magnet catches on both axes at once.
    func cycleSize(_ i: Int) {
        guard i >= 0, i < widgets.count else { return }
        let r = widgets[i].rect
        let current = preset(of: r)
        let next = current?.next ?? DesktopWidgetSize.nearest(to: pointSize(of: r))
        let s = fractionalSize(next)
        setWidget(clamped(WidgetPlacement(rect: CGRect(x: r.midX - s.width / 2,
                                                       y: r.midY - s.height / 2,
                                                       width: s.width, height: s.height))), at: i)
    }

    private func clampSelection() {
        if case .widget(let i) = selection, i >= widgets.count {
            selection = widgets.isEmpty ? nil : .widget(widgets.count - 1)
        }
    }

    // MARK: - Config bridge

    /// The placements as `Config.widgets` wants them.
    var widgetRects: [WidgetRect] {
        widgets.map {
            WidgetRect(x: Float($0.rect.minX), y: Float($0.rect.minY),
                       w: Float($0.rect.width), h: Float($0.rect.height),
                       wetness: $0.wetness)
        }
    }

    /// Take fractional rectangles from the config and make them placements.
    /// Nothing is reshaped on the way in: what the user measured is what comes
    /// back, and `preset(of:)` works out afterwards whether it happens to be one
    /// of the four.
    func setWidgetRects(_ rects: [WidgetRect]) {
        setWidgets(rects.map {
            WidgetPlacement(wetnessFromConfig: $0.wetness,
                            rect: CGRect(x: CGFloat($0.x), y: CGFloat($0.y),
                                         width: CGFloat($0.w), height: CGFloat($0.h)))
        })
    }

    // MARK: - Rectangles and sizes

    /// A preset's size as a fraction of the reference screen.
    func fractionalSize(_ s: DesktopWidgetSize) -> CGSize {
        CGSize(width: s.points.width / max(1, screenPoints.width),
               height: s.points.height / max(1, screenPoints.height))
    }

    /// A fractional rectangle's size in points on the reference screen.
    func pointSize(of r: CGRect) -> CGSize {
        CGSize(width: r.width * screenPoints.width, height: r.height * screenPoints.height)
    }

    /// The preset this rectangle IS, or nil for a size of the user's own.
    func preset(of r: CGRect) -> DesktopWidgetSize? {
        DesktopWidgetSize.exact(pointSize(of: r))
    }

    /// The rounding to draw a widget of this size with, in points.
    ///
    /// A preset gets its own radius. Anything else is scaled off the nearest
    /// preset by how much smaller or larger it is, so a hand-sized widget still
    /// looks like a widget rather than jumping between two fixed roundings.
    func cornerRadiusPoints(for r: CGRect) -> CGFloat {
        let s = pointSize(of: r)
        let p = DesktopWidgetSize.nearest(to: s)
        let reference = min(p.points.width, p.points.height)
        let mine = min(s.width, s.height)
        let scale = reference > 1 ? min(1.6, max(0.5, mine / reference)) : 1
        return p.cornerRadius * scale
    }

    func rect(of ref: Ref) -> CGRect? {
        switch ref {
        case .dock: return dock
        case .widget(let i):
            guard i >= 0, i < widgets.count else { return nil }
            return widgets[i].rect
        }
    }

    /// Keep a rectangle entirely on the screen. One that is half off the edge
    /// cannot be grabbed again, and neither a widget nor the dock can be there.
    func clamped(_ r: CGRect) -> CGRect {
        var q = r
        q.origin.x = min(max(0, q.origin.x), max(0, 1 - q.width))
        q.origin.y = min(max(0, q.origin.y), max(0, 1 - q.height))
        return q
    }

    func clamped(_ p: WidgetPlacement) -> WidgetPlacement {
        WidgetPlacement(rect: clamped(p.rect))
    }

    /// Write a rectangle back to whatever it belongs to.
    func write(_ r: CGRect, to ref: Ref) {
        switch ref {
        case .dock:
            dock = r
            dockIsUserPlaced = true
        case .widget(let i):
            setWidget(WidgetPlacement(rect: r), at: i)
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
        /// Which grips it offers. Empty for the menu bar.
        var handles: [Int]
    }

    var elements: [Element] {
        var out: [Element] = []
        if menuBarHeight > 0.001 {
            out.append(Element(ref: nil,
                               rect: CGRect(x: 0, y: 0, width: 1, height: menuBarHeight),
                               label: "Menu bar", wet: wetMenuBar,
                               radiusPoints: 0, editable: false, handles: []))
        }
        if let d = dock {
            // The dock is a slab with a very round end. Half its thickness caps
            // the radius, so a thin dock reads as a pill and a fat one as a
            // rounded slab, which is what the real one does.
            let thickness = min(d.height * screenPoints.height, d.width * screenPoints.width)
            out.append(Element(ref: .dock, rect: d, label: "Dock", wet: wetDock,
                               radiusPoints: min(18, thickness / 2), editable: true,
                               handles: ResizeHandle.edges))
        }
        for (i, w) in widgets.enumerated() {
            out.append(Element(ref: .widget(i), rect: w.rect,
                               label: "Widget \(i + 1)", wet: wetWidgets,
                               radiusPoints: cornerRadiusPoints(for: w.rect),
                               editable: true, handles: ResizeHandle.all))
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

    // MARK: - Suggestions
    //
    // What the detector thinks it saw, held apart from what the user has said.

    struct Suggestion: Equatable {
        enum Kind: Equatable { case widget, dock }
        var id: Int
        var kind: Kind
        /// Fractions, y down.
        var rect: CGRect
    }

    private(set) var suggestions: [Suggestion] = []
    private var nextSuggestionID = 1

    /// One line saying why there is or is not a suggestion layer. Shown
    /// verbatim; nil while nothing has been attempted.
    var suggestionNote: String? { didSet { notify(.suggestions) } }

    /// Replace the suggestion layer with a detector's answer.
    ///
    /// Anything that lands on work the user has already done is dropped HERE,
    /// before it is ever drawn — so "hand-placed wins" is a property of the
    /// model rather than a rule the drawing code has to remember. A suggestion
    /// the user has to look at and reject is nearly as bad as one that
    /// overwrote them.
    func setSuggestions(widgets suggestedWidgets: [CGRect], dock suggestedDock: CGRect?) {
        var out: [Suggestion] = []
        for r in suggestedWidgets where !collidesWithPlacement(r) {
            out.append(Suggestion(id: nextSuggestionID, kind: .widget, rect: clamped(r)))
            nextSuggestionID += 1
        }
        // The dock is only ever suggested when the current one is still the
        // derived guess. Once the user has pulled it to a length they measured,
        // a detector that reads 23% short must not be allowed to offer it back.
        if let d = suggestedDock, !dockIsUserPlaced {
            out.append(Suggestion(id: nextSuggestionID, kind: .dock, rect: clamped(d)))
            nextSuggestionID += 1
        }
        suggestions = out
        notify(.suggestions)
    }

    /// Does this rectangle land on something the user already placed?
    ///
    /// Overlap against the SMALLER of the two areas, so a small suggestion
    /// sitting inside a large placement counts as a collision even though it
    /// covers little of it. A third is the threshold: two real widgets never
    /// overlap that much, and two readings of the same widget always do.
    private func collidesWithPlacement(_ r: CGRect) -> Bool {
        for w in widgets {
            let i = w.rect.intersection(r)
            guard !i.isNull, i.width > 0, i.height > 0 else { continue }
            let smaller = min(w.rect.width * w.rect.height, r.width * r.height)
            if smaller > 0, (i.width * i.height) / smaller > 0.33 { return true }
        }
        return false
    }

    func suggestion(at p: CGPoint) -> Suggestion? {
        for s in suggestions.reversed() where s.rect.contains(p) { return s }
        return nil
    }

    /// Take a suggestion at its word. Returns false when it had gone stale.
    @discardableResult
    func acceptSuggestion(_ id: Int) -> Bool {
        guard let i = suggestions.firstIndex(where: { $0.id == id }) else { return false }
        let s = suggestions.remove(at: i)
        switch s.kind {
        case .widget:
            addWidget(WidgetPlacement(rect: s.rect))
        case .dock:
            dock = s.rect
            dockIsUserPlaced = true
            selection = .dock
        }
        notify(.suggestions)
        commit()
        return true
    }

    func dismissSuggestion(_ id: Int) {
        guard let i = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions.remove(at: i)
        notify(.suggestions)
    }

    func acceptAllSuggestions() {
        guard !suggestions.isEmpty else { return }
        for s in suggestions {
            switch s.kind {
            case .widget: widgets.append(WidgetPlacement(rect: s.rect))
            case .dock:
                dock = s.rect
                dockIsUserPlaced = true
            }
        }
        suggestions.removeAll()
        notify(.geometry)
        notify(.suggestions)
        commit()
    }

    func dismissAllSuggestions() {
        guard !suggestions.isEmpty else { return }
        suggestions.removeAll()
        notify(.suggestions)
    }

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
    /// widget column at; every other element's edges and centre; the two gutter
    /// offsets, which put a widget exactly beside another at the spacing the
    /// system itself would have used; and — for the dock — the edges of the
    /// rectangle `Furniture.desktop` derived, so the automatic answer is
    /// somewhere you can get back to.
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
        if excluding == .dock, let d = derivedDock {
            t.append(contentsOf: vertical ? [d.minX, d.midX, d.maxX] : [d.minY, d.midY, d.maxY])
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

    /// Resize by one handle: the whole rule, in one place, for both editors.
    ///
    /// Two kinds of magnet, in a deliberate order.
    ///
    /// First POSITIONAL: the moving edge is pulled onto a guide — the screen's
    /// edges and centre, another rectangle's edges, the dock's derived extent.
    /// An edge dragged deliberately onto a line the user can see is the more
    /// specific intention, so it wins.
    ///
    /// Then DIMENSIONAL, and only on an axis where nothing positional caught:
    /// the width or the height is pulled onto one of the preset dimensions, by
    /// moving the same edge and no other. That is what makes the four canonical
    /// sizes strong magnets rather than a cage — pull a small widget sideways
    /// and it stops at 329 and again at 677 on the way, but it does not have to
    /// stop there.
    ///
    /// The opposite edge is never touched: `ResizeHandle.edges` gives no handle
    /// both edges of one axis, so "pinned" is structural rather than something
    /// this function has to be careful about.
    func resizing(_ start: CGRect, handle: Int, dx: CGFloat, dy: CGFloat,
                  ref: Ref, tolerance: CGSize, minimum: CGFloat,
                  presetMagnets: Bool) -> Snap {
        let e = ResizeHandle.edges(handle)
        var minX = start.minX + (e.left ? dx : 0)
        var maxX = start.maxX + (e.right ? dx : 0)
        var minY = start.minY + (e.top ? dy : 0)
        var maxY = start.maxY + (e.bottom ? dy : 0)

        var snap = Snap(rect: .zero)
        var caughtX = false, caughtY = false
        if e.left {
            let v = snappingEdge(minX, vertical: true, moving: ref,
                                 tolerance: tolerance.width, into: &snap)
            caughtX = v != minX; minX = v
        }
        if e.right {
            let v = snappingEdge(maxX, vertical: true, moving: ref,
                                 tolerance: tolerance.width, into: &snap)
            caughtX = v != maxX; maxX = v
        }
        if e.top {
            let v = snappingEdge(minY, vertical: false, moving: ref,
                                 tolerance: tolerance.height, into: &snap)
            caughtY = v != minY; minY = v
        }
        if e.bottom {
            let v = snappingEdge(maxY, vertical: false, moving: ref,
                                 tolerance: tolerance.height, into: &snap)
            caughtY = v != maxY; maxY = v
        }

        if presetMagnets {
            let tol = DesktopWidgetSize.magnet
            if (e.left || e.right), !caughtX,
               let w = magnet(points: (maxX - minX) * screenPoints.width,
                              to: DesktopWidgetSize.presetWidths, tolerance: tol) {
                let frac = w / max(1, screenPoints.width)
                if e.left { minX = maxX - frac } else { maxX = minX + frac }
                snap.names.insert("w:\(Int(w))")
            }
            if (e.top || e.bottom), !caughtY,
               let h = magnet(points: (maxY - minY) * screenPoints.height,
                              to: DesktopWidgetSize.presetHeights, tolerance: tol) {
                let frac = h / max(1, screenPoints.height)
                if e.top { minY = maxY - frac } else { maxY = minY + frac }
                snap.names.insert("h:\(Int(h))")
            }
        }

        if maxX - minX < minimum { if e.left { minX = maxX - minimum } else { maxX = minX + minimum } }
        if maxY - minY < minimum { if e.top { minY = maxY - minimum } else { maxY = minY + minimum } }
        snap.rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return snap
    }

    private func magnet(points v: CGFloat, to targets: [CGFloat],
                        tolerance: CGFloat) -> CGFloat? {
        var best: CGFloat?
        for t in targets where abs(t - v) <= tolerance
            && (best == nil || abs(t - v) < abs(best! - v)) { best = t }
        return best
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

    /// How a widget's size reads: the preset when it is exactly one, and the
    /// measurement when it is not. The user asked for both, and the difference
    /// is the whole point of free resizing — "Medium" is a claim about what
    /// macOS drew, and "340 × 160 pt" is a claim about what was measured.
    func sizeDescription(of r: CGRect) -> String {
        let s = pointSize(of: r)
        if let p = preset(of: r) {
            return "\(p.name), \(p.cells.across) × \(p.cells.down)"
        }
        return String(format: "Custom, %.0f × %.0f pt", s.width, s.height)
    }

    /// The dock in the units somebody setting it exactly would want: points for
    /// the measurement, percentages for the thing that survives a resolution
    /// change.
    func dockDescription(_ r: CGRect) -> String {
        let p = pointSize(of: r)
        return String(format: "x %.0f pt (%.1f%%), y %.0f pt (%.1f%%), %.0f × %.0f pt "
                            + "(%.1f%% × %.1f%%)",
                      r.minX * screenPoints.width, r.minX * 100,
                      r.minY * screenPoints.height, r.minY * 100,
                      p.width, p.height, r.width * 100, r.height * 100)
    }

    /// Change the selected widget's wetness. Clamped, and a no-op for the dock,
    /// which has no per-instance setting — it is one object, so the global
    /// switch already says everything there is to say about it.
    func setSelectedWetness(_ v: Float) {
        guard case .widget(let i)? = selection, i < widgets.count else { return }
        var w = widgets[i]
        w.wetness = max(0, min(1, v))
        setWidget(w, at: i)
    }

    /// Nudge it, for the keyboard. Returns the new value so the caller can say
    /// what happened without re-reading the model.
    @discardableResult
    func nudgeSelectedWetness(by delta: Float) -> Float? {
        guard case .widget(let i)? = selection, i < widgets.count else { return nil }
        let v = max(0, min(1, widgets[i].wetness + delta))
        setSelectedWetness(v)
        return v
    }

    /// The status line both editors show. One sentence, one wording.
    var selectionDescription: String {
        // Wetness is appended rather than given its own line, because it is a
        // property OF the selected thing and belongs in the sentence that
        // describes it. Only shown when it is not the default: a line that says
        // "100% wet" on every widget is noise, and the reader learns to skip it.
        if case .widget(let i)? = selection, i < widgets.count,
           widgets[i].wetness < 0.999 {
            return baseSelectionDescription
                 + String(format: "  ·  %.0f%% wet", widgets[i].wetness * 100)
        }
        return baseSelectionDescription
    }

    private var baseSelectionDescription: String {
        guard let ref = selection, let r = rect(of: ref) else {
            if !suggestions.isEmpty {
                return "\(suggestions.count) suggested rectangle"
                     + "\(suggestions.count == 1 ? "" : "s") — click one to keep it, "
                     + "⌥-click to dismiss it."
            }
            return widgets.isEmpty && dock == nil
                ? "Nothing placed yet — drag a rectangle over each widget."
                : "Click a rectangle to select it. Drag to move it, take a handle to resize it, "
                + "Space for the next preset size, ⌫ to remove it."
        }
        switch ref {
        case .dock:
            return "Dock — " + dockDescription(r)
        case .widget(let i):
            return String(format: "Widget %d — %@, at x %.0f%%, y %.0f%%",
                          i + 1, sizeDescription(of: r), r.minX * 100, r.minY * 100)
        }
    }
}
