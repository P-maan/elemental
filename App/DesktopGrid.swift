//  DesktopGrid.swift — the editable miniature of your display.
//
//  This is the primary interface of the Elements pane, not a fallback for when
//  detection fails. Detection's job is to save the user from placing eight
//  rectangles by hand; this is where they are made right, and it has to be good
//  enough that placing them all by hand is merely tedious rather than hopeless.
//
//  It is a little screen you can work directly: drag a widget to move it, take
//  a handle to resize it, arrow-key it a hair at a time, delete it. The dock is
//  in there too, because a detected dock that could not be corrected would be
//  worse than no detected dock at all (see `Config.dockRect`).
//
//  ---- Haptics
//
//  Every snap and every detent crossed while dragging fires
//  `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, ...)` — the
//  pattern Preview and Keynote use for their snap guides, so it is already the
//  meaning "you have landed on a line" carries on this hardware. It fires on the
//  TRANSITION into a snap, never continuously: a drag that stays parked on a
//  guide buzzes once, not sixty times a second.
//
//  The performer is guarded. A Mac with a non-Force-Touch trackpad, or a mouse
//  and no trackpad at all, has none, and asking for feedback there must be a
//  no-op rather than a crash.
//
//  ---- Where the work happens
//
//  Dragging redraws this view and nothing else. The config is committed on
//  MOUSE-UP, not per mouse-move: a commit re-syncs every other pane and pushes
//  new collision geometry into the live wallpaper, which is not something to do
//  sixty times a second. See the performance note at the top of Settings.swift.

import AppKit

// MARK: - Haptics

/// The alignment detent, or nothing at all on hardware that cannot do it.
enum Haptics {

    /// Optional on purpose. `defaultPerformer` is declared non-optional by
    /// AppKit, but the whole point is that plenty of Macs cannot do this, so it
    /// is taken as an optional and guarded — a mouse-only desk must get silence,
    /// not a trap.
    private static var performer: NSHapticFeedbackPerformer? {
        let p: NSHapticFeedbackPerformer? = NSHapticFeedbackManager.defaultPerformer
        return p
    }

    /// One detent. Call on the transition into a snap, never per frame.
    static func alignment() {
        guard let p = performer else { return }
        p.perform(.alignment, performanceTime: .drawCompleted)
    }

    /// A heavier one, for a control landing on a named stop rather than a line.
    static func level() {
        guard let p = performer else { return }
        p.perform(.levelChange, performanceTime: .drawCompleted)
    }

    /// True when this Mac can actually do it. Used only to word the UI honestly.
    static var available: Bool { performer != nil }
}

/// A slider that clicks as it passes each detent.
///
/// `NSSlider` with tick marks snaps but says nothing, so a slider dragged with
/// the pointer outside the track gives no clue where the stops are. One
/// `.alignment` tap per detent crossed makes them findable without looking.
final class DetentSlider: NSSlider {

    /// Detent spacing in slider units. 0.1 over a 0...1 range is ten stops.
    var detent: Double = 0.1
    private var lastIndex: Int?

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        let i = Int((doubleValue / max(0.0001, detent)).rounded())
        if let last = lastIndex, last != i { Haptics.alignment() }
        lastIndex = i
        return super.sendAction(action, to: target)
    }

    /// Called when the value is set programmatically, so the next drag does not
    /// fire a spurious detent for the jump.
    func resyncDetent() { lastIndex = Int((doubleValue / max(0.0001, detent)).rounded()) }
}

// MARK: - The grid

/// One thing on the desktop, in fractions of the screen with y down — the same
/// convention `WidgetRect`, `Furniture` and the simulation all use.
struct DesktopElement: Equatable {
    enum Kind: Equatable { case dock, widget(Int), menuBar }
    var kind: Kind
    var rect: CGRect
    var label: String
    /// Whether weather is allowed to mark it, for the lit-up styling.
    var wet: Bool
    /// The menu bar's geometry belongs to macOS; only its switch is ours.
    var editable: Bool
}

final class DesktopGridView: NSView {

    // ---- model

    /// Widget rectangles, fractional. The pane owns the config; this owns the
    /// live copy being dragged.
    var widgets: [WidgetRect] = [] { didSet { needsDisplay = true } }
    /// The dock, fractional. Nil means "no dock found or configured".
    var dock: CGRect? { didSet { needsDisplay = true } }
    /// Menu bar height as a fraction of the screen, 0 for none.
    var menuBarHeight: CGFloat = 0.025 { didSet { needsDisplay = true } }

    var wetDock = true { didSet { needsDisplay = true } }
    var wetWidgets = true { didSet { needsDisplay = true } }
    var wetMenuBar = false { didSet { needsDisplay = true } }
    /// 0...1, dims the lit-up styling the way the strength slider dims the effect.
    var strength: CGFloat = 1 { didSet { needsDisplay = true } }

    /// A faint copy of the user's screenshot behind the rectangles, so what has
    /// been detected can be checked against what was actually on screen. This is
    /// the difference between "trust these numbers" and "look, that is your
    /// dock".
    var backdrop: NSImage? { didSet { needsDisplay = true } }

    /// Screen shape. Read from the display at build time so the miniature is
    /// the user's screen and not a generic 16:9.
    var aspect: CGFloat = 16.0 / 10.0

    // ---- selection and callbacks

    enum Selection: Equatable { case none, dock, widget(Int) }
    private(set) var selection: Selection = .none {
        didSet { if selection != oldValue { needsDisplay = true; onSelectionChange?() } }
    }

    /// Cheap, fires while dragging. Redraw only — never commit from here.
    var onLiveChange: (() -> Void)?
    /// Fires on mouse-up and on discrete edits. Commit from here.
    var onCommit: (() -> Void)?
    var onSelectionChange: (() -> Void)?

    // ---- geometry

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var widthC: NSLayoutConstraint!
    private var heightC: NSLayoutConstraint!

    init(width: CGFloat = 320) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: width / (16.0 / 10.0)))
        translatesAutoresizingMaskIntoConstraints = false
        if let s = NSScreen.main, s.frame.height > 1 {
            aspect = s.frame.width / s.frame.height
        }
        widthC = widthAnchor.constraint(equalToConstant: width)
        heightC = heightAnchor.constraint(equalToConstant: (width / aspect).rounded())
        NSLayoutConstraint.activate([widthC, heightC])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Your desktop. Drag the rectangles to match what is on your screen.")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The screen's rectangle inside the view, inset for the bezel.
    var screenRect: NSRect { bounds.insetBy(dx: 5, dy: 5) }

    private func toView(_ r: CGRect) -> NSRect {
        let s = screenRect
        return NSRect(x: s.minX + r.minX * s.width, y: s.minY + r.minY * s.height,
                      width: r.width * s.width, height: r.height * s.height)
    }

    private func toFrac(_ p: NSPoint) -> CGPoint {
        let s = screenRect
        return CGPoint(x: (p.x - s.minX) / max(1, s.width), y: (p.y - s.minY) / max(1, s.height))
    }

    /// Elements in back-to-front order.
    var elements: [DesktopElement] {
        var out: [DesktopElement] = []
        if menuBarHeight > 0.001 {
            out.append(DesktopElement(kind: .menuBar,
                                      rect: CGRect(x: 0, y: 0, width: 1, height: menuBarHeight),
                                      label: "Menu bar", wet: wetMenuBar, editable: false))
        }
        if let d = dock {
            out.append(DesktopElement(kind: .dock, rect: d, label: "Dock",
                                      wet: wetDock, editable: true))
        }
        for (i, w) in widgets.enumerated() {
            out.append(DesktopElement(kind: .widget(i),
                                      rect: CGRect(x: CGFloat(w.x), y: CGFloat(w.y),
                                                   width: CGFloat(w.w), height: CGFloat(w.h)),
                                      label: "Widget \(i + 1)", wet: wetWidgets, editable: true))
        }
        return out
    }

    // MARK: - Drawing

    override func draw(_ dirty: NSRect) {
        let s = screenRect
        let screen = NSBezierPath(roundedRect: s, xRadius: 9, yRadius: 9)

        NSColor.windowBackgroundColor.setFill()
        screen.fill()

        NSGraphicsContext.saveGraphicsState()
        screen.addClip()
        if let img = backdrop {
            // The real screenshot, dimmed, so the rectangles can be checked
            // against the thing they are meant to describe.
            // `respectFlipped` matters: this view is flipped so that fractions
            // read y-down like `WidgetRect`, and without it the screenshot
            // draws upside down under rectangles that are the right way up.
            img.draw(in: s, from: .zero, operation: .sourceOver, fraction: 0.55,
                     respectFlipped: true, hints: nil)
            NSColor.windowBackgroundColor.withAlphaComponent(0.28).setFill()
            s.fill()
        } else {
            let sky = NSGradient(colors: [
                NSColor(calibratedRed: 0.19, green: 0.40, blue: 0.70, alpha: 1),
                NSColor(calibratedRed: 0.60, green: 0.75, blue: 0.89, alpha: 1),
            ])
            sky?.draw(in: s, angle: -90)
        }
        NSGraphicsContext.restoreGraphicsState()

        for e in elements {
            let r = toView(e.rect).integral
            let radius: CGFloat = {
                switch e.kind {
                case .menuBar: return 2
                case .dock: return min(7, r.height / 2)
                case .widget: return 5
                }
            }()
            let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

            NSColor.windowBackgroundColor.withAlphaComponent(0.88).setFill()
            p.fill()
            if e.wet {
                NSColor.controlAccentColor.withAlphaComponent(0.26 + 0.44 * strength).setFill()
                p.fill()
                NSColor.controlAccentColor.setStroke()
                p.lineWidth = 1.5
                p.stroke()
            } else {
                NSColor.separatorColor.setStroke()
                p.lineWidth = 1
                p.stroke()
            }

            if isSelected(e.kind) {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2.5, dy: -2.5),
                                        xRadius: radius + 2, yRadius: radius + 2)
                NSColor.controlAccentColor.setStroke()
                ring.lineWidth = 2
                ring.stroke()
                if e.editable { drawHandles(r) }
            }

            let labelSize: CGFloat = big ? 11 : 8
            if r.height >= labelSize + 5, r.width >= labelSize * 3 {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: labelSize, weight: e.wet ? .semibold : .regular),
                    .foregroundColor: e.wet ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ]
                let str = NSAttributedString(string: e.label, attributes: attrs)
                let sz = str.size()
                if sz.width < r.width - 4 {
                    str.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
                }
            }
        }

        // Snap guides, while a drag is holding one.
        if !guides.isEmpty {
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            for g in guides {
                let line = NSBezierPath()
                line.lineWidth = 1
                line.setLineDash([3, 3], count: 2, phase: 0)
                if g.vertical {
                    let x = (s.minX + g.value * s.width).rounded() + 0.5
                    line.move(to: NSPoint(x: x, y: s.minY)); line.line(to: NSPoint(x: x, y: s.maxY))
                } else {
                    let y = (s.minY + g.value * s.height).rounded() + 0.5
                    line.move(to: NSPoint(x: s.minX, y: y)); line.line(to: NSPoint(x: s.maxX, y: y))
                }
                line.stroke()
            }
        }

        NSColor.separatorColor.setStroke()
        screen.lineWidth = 1
        screen.stroke()
    }

    // ---- handle size
    //
    // A 3pt dot with a 12pt hit box is fine on a 320pt thumbnail and impossible
    // on the full-size editor, where the same rectangle is more than twice as
    // wide and the pointer has real room to work in. Both scale with the
    // miniature so a handle is always worth aiming at.

    private var big: Bool { bounds.width >= 560 }
    private var handleRadius: CGFloat { big ? 5.5 : 3 }
    private var handleSlop: CGFloat { big ? 11 : 6 }

    private func drawHandles(_ r: NSRect) {
        let hr = handleRadius
        for p in handlePoints(r) {
            let box = NSRect(x: p.x - hr, y: p.y - hr, width: hr * 2, height: hr * 2)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: box).fill()
            NSColor.controlAccentColor.setStroke()
            let o = NSBezierPath(ovalIn: box)
            o.lineWidth = 1.5
            o.stroke()
        }
    }

    /// The eight resize handles, in the order `Edge` below indexes them.
    private func handlePoints(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.minX, y: r.midY), NSPoint(x: r.maxX, y: r.midY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)]
    }

    private func isSelected(_ k: DesktopElement.Kind) -> Bool {
        switch (selection, k) {
        case (.dock, .dock): return true
        case (.widget(let a), .widget(let b)): return a == b
        default: return false
        }
    }

    // MARK: - Snapping

    struct Guide: Equatable { var vertical: Bool; var value: CGFloat }
    private var guides: [Guide] = []
    /// Which snaps are currently engaged, so a haptic fires on the transition in
    /// rather than every frame the drag stays parked on the line.
    private var engaged: Set<String> = []

    /// Snap distance in fractions, derived from a fixed 4.5pt in the view — so
    /// it feels the same however big the miniature is drawn.
    private var snapTolerance: CGFloat { 4.5 / max(1, screenRect.width) }

    /// Everything worth landing on: the screen's own edges and centre lines, a
    /// twelfth-of-the-screen grid, and the edges and centres of every OTHER
    /// element.
    private func targets(vertical: Bool, excluding: DesktopElement.Kind?) -> [CGFloat] {
        var t: [CGFloat] = [0, 0.5, 1]
        for i in 1..<12 { t.append(CGFloat(i) / 12) }
        for e in elements where e.kind != excluding {
            if vertical { t.append(contentsOf: [e.rect.minX, e.rect.midX, e.rect.maxX]) }
            else { t.append(contentsOf: [e.rect.minY, e.rect.midY, e.rect.maxY]) }
        }
        return t
    }

    /// Pull `values` (the moving edges) onto the nearest target. Returns the
    /// offset to apply and records the guides to draw.
    private func snapOffset(_ values: [CGFloat], vertical: Bool,
                            excluding: DesktopElement.Kind?,
                            into names: inout Set<String>) -> CGFloat {
        let tol = snapTolerance
        var best: (delta: CGFloat, target: CGFloat)?
        for v in values {
            for t in targets(vertical: vertical, excluding: excluding) {
                let d = t - v
                if abs(d) <= tol, best == nil || abs(d) < abs(best!.delta) {
                    best = (d, t)
                }
            }
        }
        guard let b = best else { return 0 }
        names.insert("\(vertical ? "x" : "y"):\(Int((b.target * 1000).rounded()))")
        guides.append(Guide(vertical: vertical, value: b.target))
        return b.delta
    }

    /// Move the whole rectangle onto the nearest guide, and buzz once for each
    /// newly engaged line.
    private func snapped(_ r: CGRect, moving: DesktopElement.Kind) -> CGRect {
        guides.removeAll()
        var names: Set<String> = []
        let dx = snapOffset([r.minX, r.midX, r.maxX], vertical: true,
                            excluding: moving, into: &names)
        let dy = snapOffset([r.minY, r.midY, r.maxY], vertical: false,
                            excluding: moving, into: &names)
        finish(names)
        return r.offsetBy(dx: dx, dy: dy)
    }

    /// Snap ONE edge, leaving the opposite edge exactly where it is.
    ///
    /// Resizing cannot go through `snapped`: offsetting the whole rectangle to
    /// bring the dragged edge onto a guide drags the anchored edge off wherever
    /// the user put it, so the box slides instead of growing.
    private func snapEdge(_ v: CGFloat, vertical: Bool, moving: DesktopElement.Kind,
                          into names: inout Set<String>) -> CGFloat {
        let tol = snapTolerance
        var best: CGFloat?
        for t in targets(vertical: vertical, excluding: moving)
        where abs(t - v) <= tol && (best == nil || abs(t - v) < abs(best! - v)) {
            best = t
        }
        guard let b = best else { return v }
        names.insert("\(vertical ? "x" : "y"):\(Int((b * 1000).rounded()))")
        guides.append(Guide(vertical: vertical, value: b))
        return b
    }

    /// Buzz once per newly engaged guide, then remember what is engaged.
    private func finish(_ names: Set<String>) {
        if !names.subtracting(engaged).isEmpty { Haptics.alignment() }
        engaged = names
    }

    // MARK: - Pointer handling
    //
    // Split out from `mouseDown`/`mouseDragged` so the verification harness can
    // drive a drag without a mouse — there is no other way to prove that the
    // editor, the snapping and the haptics actually work, since the harness
    // cannot click.

    /// Which part of the selection a drag has hold of. -1 is the body.
    private var grabbed: Int = -1
    private var dragOrigin: CGPoint = .zero
    private var rectAtGrab: CGRect = .zero
    private var dragging = false

    /// Smallest a rectangle may be dragged to, as a fraction. Below this it
    /// cannot be grabbed again.
    private let minSize: CGFloat = 0.02

    func pointerDown(_ p: NSPoint) {
        window?.makeFirstResponder(self)
        guides.removeAll(); engaged.removeAll()

        // A handle of the current selection wins over anything underneath it.
        if let r = rect(of: selection) {
            let vr = toView(r)
            let slop = handleSlop
            for (i, hp) in handlePoints(vr).enumerated()
            where NSRect(x: hp.x - slop, y: hp.y - slop,
                         width: slop * 2, height: slop * 2).contains(p) {
                grabbed = i
                dragOrigin = toFrac(p)
                rectAtGrab = r
                dragging = true
                return
            }
        }
        // Otherwise pick the front-most element under the pointer.
        for e in elements.reversed() where e.editable && toView(e.rect).contains(p) {
            selection = select(e.kind)
            grabbed = -1
            dragOrigin = toFrac(p)
            rectAtGrab = e.rect
            dragging = true
            return
        }
        selection = .none
        dragging = false
        needsDisplay = true
    }

    func pointerDragged(_ p: NSPoint) {
        guard dragging, let kind = kind(of: selection) else { return }
        let now = toFrac(p)
        let dx = now.x - dragOrigin.x, dy = now.y - dragOrigin.y
        var r = rectAtGrab

        if grabbed < 0 {
            r = r.offsetBy(dx: dx, dy: dy)
            r = snapped(r, moving: kind)
            // Never off the screen entirely — a rectangle you cannot see is a
            // rectangle you cannot fix.
            r.origin.x = min(max(r.origin.x, -r.width * 0.5), 1 - r.width * 0.5)
            r.origin.y = min(max(r.origin.y, -r.height * 0.5), 1 - r.height * 0.5)
        } else {
            var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
            // Which edges this handle owns. 0,3,5 are the left column; 0,1,2
            // the top row; and so on round the eight.
            let movesLeft = grabbed == 0 || grabbed == 3 || grabbed == 5
            let movesRight = grabbed == 2 || grabbed == 4 || grabbed == 7
            let movesTop = grabbed <= 2
            let movesBottom = grabbed >= 5
            if movesLeft { minX += dx }
            if movesRight { maxX += dx }
            if movesTop { minY += dy }
            if movesBottom { maxY += dy }

            guides.removeAll()
            var names: Set<String> = []
            if movesLeft { minX = snapEdge(minX, vertical: true, moving: kind, into: &names) }
            if movesRight { maxX = snapEdge(maxX, vertical: true, moving: kind, into: &names) }
            if movesTop { minY = snapEdge(minY, vertical: false, moving: kind, into: &names) }
            if movesBottom { maxY = snapEdge(maxY, vertical: false, moving: kind, into: &names) }
            finish(names)

            if maxX - minX < minSize { if movesLeft { minX = maxX - minSize } else { maxX = minX + minSize } }
            if maxY - minY < minSize { if movesTop { minY = maxY - minSize } else { maxY = minY + minSize } }
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        write(r, to: selection)
        onLiveChange?()
        needsDisplay = true
    }

    func pointerUp() {
        guard dragging else { return }
        dragging = false
        guides.removeAll()
        engaged.removeAll()
        needsDisplay = true
        onCommit?()
    }

    override func mouseDown(with event: NSEvent) {
        pointerDown(convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        pointerDragged(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) { pointerUp() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Three speeds, so fine adjustment never needs pixel-accurate mousing:
        // ⌥ a hair, plain a step, ⇧ a stride. On a 4112px display ⌥ is about
        // four pixels.
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 0.02
                          : event.modifierFlags.contains(.option) ? 0.001 : 0.004
        var handled = true
        switch event.keyCode {
        case 123: nudge(dx: -step, dy: 0, pull: step)   // left
        case 124: nudge(dx: step, dy: 0, pull: step)    // right
        case 125: nudge(dx: 0, dy: step, pull: step)    // down
        case 126: nudge(dx: 0, dy: -step, pull: step)   // up
        case 51, 117: removeSelected()           // delete / forward delete
        case 48: cycleSelection()                // tab
        default: handled = false
        }
        if !handled { super.keyDown(with: event) }
    }

    /// `pull` is how far a nudge is allowed to be dragged onto a guide — one
    /// step, so a fine ⌥-nudge is not yanked back onto a line it was trying to
    /// creep away from.
    private func nudge(dx: CGFloat, dy: CGFloat, pull: CGFloat = 0.004) {
        guard var r = rect(of: selection) else { return }
        r = r.offsetBy(dx: dx, dy: dy)
        // A keyboard nudge that lands exactly on a guide should feel like the
        // drag that lands on the same guide.
        if let k = kind(of: selection) {
            var names: Set<String> = []
            guides.removeAll()
            let sx = snapOffset([r.minX, r.midX, r.maxX], vertical: true, excluding: k, into: &names)
            let sy = snapOffset([r.minY, r.midY, r.maxY], vertical: false, excluding: k, into: &names)
            if abs(sx) < pull { r.origin.x += sx }
            if abs(sy) < pull { r.origin.y += sy }
            if !names.subtracting(engaged).isEmpty { Haptics.alignment() }
            engaged = names
            guides.removeAll()
        }
        write(r, to: selection)
        needsDisplay = true
        onCommit?()
    }

    func cycleSelection() {
        let all = elements.filter(\.editable).map(\.kind)
        guard !all.isEmpty else { return }
        guard let k = kind(of: selection), let i = all.firstIndex(of: k) else {
            selection = select(all[0]); return
        }
        selection = select(all[(i + 1) % all.count])
        Haptics.alignment()
    }

    // MARK: - Edits

    func addWidget() {
        // Dropped in the middle at a plausible widget size, selected, ready to
        // be dragged where it belongs.
        let w: CGFloat = 0.11, h: CGFloat = w * aspect * 1.0
        widgets.append(WidgetRect(x: Float(0.5 - w / 2), y: Float(0.5 - h / 2),
                                  w: Float(w), h: Float(h)))
        selection = .widget(widgets.count - 1)
        Haptics.level()
        needsDisplay = true
        onCommit?()
    }

    /// Which the Remove button and ⌫ apply to.
    ///
    /// Widgets only. The dock is not deletable, because "no dock" is not a
    /// placement — it is the Dock switch below, and removing the rectangle
    /// would only make it come back from the system estimate on the next sync,
    /// which reads as the button not working.
    var canRemoveSelection: Bool {
        if case .widget(let i) = selection { return i < widgets.count }
        return false
    }

    func removeSelected() {
        switch selection {
        case .widget(let i) where i < widgets.count:
            widgets.remove(at: i)
            selection = widgets.isEmpty ? .none : .widget(min(i, widgets.count - 1))
        case .dock, .none, .widget:
            return
        }
        Haptics.level()
        needsDisplay = true
        onCommit?()
    }

    func clearAll() {
        widgets.removeAll()
        selection = .none
        needsDisplay = true
        onCommit?()
    }

    /// Replace everything with what a screenshot yielded.
    func adopt(_ d: DetectedDesktop) {
        widgets = d.widgets.map {
            WidgetRect(x: Float($0.minX), y: Float($0.minY), w: Float($0.width), h: Float($0.height))
        }
        dock = d.dock
        if let m = d.menuBar { menuBarHeight = m }
        selection = .none
        needsDisplay = true
        onCommit?()
    }

    // MARK: - Selection plumbing

    private func select(_ k: DesktopElement.Kind) -> Selection {
        switch k {
        case .dock: return .dock
        case .widget(let i): return .widget(i)
        case .menuBar: return .none
        }
    }

    private func kind(of s: Selection) -> DesktopElement.Kind? {
        switch s {
        case .none: return nil
        case .dock: return .dock
        case .widget(let i): return .widget(i)
        }
    }

    func rect(of s: Selection) -> CGRect? {
        switch s {
        case .none: return nil
        case .dock: return dock
        case .widget(let i):
            guard i < widgets.count else { return nil }
            let w = widgets[i]
            return CGRect(x: CGFloat(w.x), y: CGFloat(w.y), width: CGFloat(w.w), height: CGFloat(w.h))
        }
    }

    private func write(_ r: CGRect, to s: Selection) {
        switch s {
        case .none: return
        case .dock: dock = r
        case .widget(let i):
            guard i < widgets.count else { return }
            widgets[i] = WidgetRect(x: Float(r.minX), y: Float(r.minY),
                                    w: Float(r.width), h: Float(r.height))
        }
    }

    /// A one-line description of what is selected, for the pane's status row.
    var selectionDescription: String {
        guard let r = rect(of: selection) else {
            return widgets.isEmpty && dock == nil
                ? "Nothing placed yet — hand in a screenshot, or add a widget."
                : "Click a rectangle to select it. Drag to move, handles to resize, ⌫ to remove."
        }
        let name: String = {
            switch selection {
            case .dock: return "Dock"
            case .widget(let i): return "Widget \(i + 1)"
            case .none: return ""
            }
        }()
        return String(format: "%@ — x %.0f%%, y %.0f%%, %.0f%% × %.0f%%",
                      name, r.minX * 100, r.minY * 100, r.width * 100, r.height * 100)
    }
}

// MARK: - Dock override

/// Fold a user-corrected dock rectangle into the collision geometry.
///
/// `Furniture.desktop` derives the dock from com.apple.dock's tile size and item
/// count, which is a good guess and not more than that — a stack, a wide
/// separator or a second display all move it. When the user has dragged the dock
/// in the Elements grid, that measurement is better than the guess, so it
/// replaces it. Nil changes nothing, which is what every user who never opens the
/// pane gets.
func applyingDockOverride(_ surfaces: [Surface], override: WidgetRect?,
                          pixelWidth W: Float, pixelHeight H: Float,
                          enabled: Bool) -> [Surface] {
    guard let o = override, enabled else { return surfaces }
    var out = surfaces.filter { $0.kind != .dock }
    out.append(Surface(x: o.x * W, y: o.y * H, w: o.w * W, h: o.h * H, kind: .dock))
    return out
}
