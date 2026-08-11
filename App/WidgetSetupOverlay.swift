//  WidgetSetupOverlay.swift — point at your furniture instead of guessing at it.
//
//  macOS publishes no API for where desktop widgets are. Everything else the
//  engine needs to collide with, it can ask the system for: the menu bar and the
//  dock's THICKNESS come out of `NSScreen.visibleFrame` exactly. Widgets come
//  from nowhere, and the dock's extent along its edge is a guess made from
//  com.apple.dock that measures about a quarter short in practice. Both have
//  been coming from `FurnitureDetector` — a contrast heuristic run over a
//  screenshot, which finds roughly half the widgets and invents a couple.
//
//  This is the other way round, and it is the user's idea: stop inferring, and
//  let them SHOW us. A translucent sheet over the real desktop, drag a box round
//  each widget, pull the dock out to its real length, done.
//
//  ---- One editor, two windows
//
//  This is not a separate editor from the miniature in the Elements pane. Both
//  are views onto one `PlacementModel` (see Placements.swift): the same
//  placements, the same snapping rules, the same commit path. The settings
//  window deliberately stays up while this is on screen, floating above it, so a
//  widget dragged here moves on the miniature under your eyes and a widget
//  dragged there lights up here — `PlacementModel.dragging` is what carries
//  that, and every drag sets it.
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
//  The dock is the one thing here that stays a free rectangle, because its
//  extent is the one measurement that is genuinely unknown rather than merely
//  unpublished. It gets resize handles; widgets get four presets.
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

// MARK: - The canvas

/// The full-screen drawing surface: dim wash, punched-out placements, and all
/// of the pointer and keyboard handling.
///
/// Coordinates are the view's own points, and the view is exactly the size of
/// the screen in points, so a placement's rectangle IS its position on the
/// screen and the presets are usable as literal constants. Flipped, so y counts
/// down from the top — the convention `WidgetRect`, `Furniture`, the simulation
/// and `PlacementModel` all share.
final class WidgetSetupCanvas: NSView {

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The geometry, shared with the Elements pane's miniature.
    let model: PlacementModel

    /// The screen this is covering, for the pixel figures in the labels.
    let screen: NSScreen

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
        case moving(ref: PlacementModel.Ref, grab: CGSize)
        /// Pulling one of the dock's eight handles. Indexed exactly as
        /// `handlePoints` below returns them.
        case resizing(ref: PlacementModel.Ref, handle: Int, start: CGPoint, rect: CGRect)
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

    /// Smallest the dock may be pulled to, as a fraction of the screen.
    private let minDockSize: CGFloat = 0.02

    // ---- snapping

    private var guides: [PlacementModel.Guide] = []
    private var engaged: Set<String> = []

    /// Eight points under the hand, as a fraction of the screen. The miniature
    /// uses four and a half points of ITS width for the same reason: the number
    /// that should stay constant is the distance the pointer has to be within,
    /// not the fraction of the model it represents.
    private var snapTolerance: CGSize {
        CGSize(width: 8 / max(1, bounds.width), height: 8 / max(1, bounds.height))
    }

    init(screen: NSScreen, model: PlacementModel) {
        self.screen = screen
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drag a rectangle over each desktop widget.")
        // A drag happening on the pane's miniature arrives here through this.
        model.observe(self) { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { model.stopObserving(self) }

    var count: Int { model.widgets.count }

    func removeSelected() {
        guard case .widget(let i) = model.selection else { return }
        model.removeWidget(at: i)
        Haptics.level()
        onChange?()
        model.commit()
    }

    func removeAll() {
        guard !model.widgets.isEmpty else { return }
        model.removeAllWidgets()
        Haptics.level()
        onChange?()
        model.commit()
    }

    // MARK: - Geometry

    /// Fractions to view points. The view is the screen at 1:1, so this is a
    /// multiply — and it is the ONLY conversion, used by the fill, the ring, the
    /// handles, the label and the hit test alike. A drag frame that does not sit
    /// exactly on its widget is almost always two of those disagreeing.
    private func toView(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX * bounds.width, y: r.minY * bounds.height,
               width: r.width * bounds.width, height: r.height * bounds.height)
    }

    private func toFrac(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x / max(1, bounds.width), y: p.y / max(1, bounds.height))
    }

    /// The rounding of the real thing. This canvas is 1:1 with the screen, so
    /// the radius in points IS the radius in view units — the miniature scales
    /// the same number down, which is what keeps the two shapes agreeing.
    private func radius(_ e: PlacementModel.Element) -> CGFloat {
        e.radiusPoints * (bounds.width / max(1, model.screenPoints.width))
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
        // The hole is cut with the SAME path the outline is stroked with, so a
        // widget's bright patch and its frame are the same shape to the pixel.
        let wash = NSBezierPath(rect: bounds)
        wash.windingRule = .evenOdd
        for e in model.elements where e.editable {
            wash.append(continuousRoundedRect(toView(e.rect), radius: radius(e)))
        }
        if let p = pending {
            wash.append(continuousRoundedRect(toView(model.rect(of: p)),
                                              radius: p.size.cornerRadius))
        }
        NSColor.black.withAlphaComponent(isPassive ? 0.22 : 0.44).setFill()
        wash.fill()

        drawGuides()

        for e in model.elements where e.editable { draw(e) }

        if case .creating(let anchor, let current) = drag { drawCreation(anchor, current) }

        if model.widgets.isEmpty, case .none = drag { drawEmptyHint() }
    }

    private func draw(_ e: PlacementModel.Element) {
        let r = toView(e.rect)
        let rad = radius(e)
        let selected = e.ref != nil && model.selection == e.ref
        let path = continuousRoundedRect(r, radius: rad)
        // The dock is a different KIND of thing from a widget — free where they
        // are preset, system-owned where they are yours — so it is drawn in a
        // different colour rather than being made to look like a big widget.
        let accent = e.ref == .dock ? NSColor.systemTeal : NSColor.controlAccentColor
        accent.withAlphaComponent(selected ? 0.22 : 0.12).setFill()
        path.fill()
        (selected ? accent : accent.withAlphaComponent(0.75)).setStroke()
        path.lineWidth = selected ? 3 : 2
        path.stroke()

        // The live link with the pane's miniature: whatever is under the hand
        // right now glows here too, even when the hand is over there.
        if let ref = e.ref, model.dragging == ref { drawDragHalo(r, radius: rad, colour: accent) }

        if selected { drawHandles(r, resizable: e.ref == .dock, colour: accent) }

        drawLabel(for: e, in: r)
    }

    private func drawLabel(for e: PlacementModel.Element, in r: NSRect) {
        switch e.ref {
        case .dock:
            let px = e.rect.width * model.screenPoints.width * screen.backingScaleFactor
            drawPill(e.label,
                     sub: String(format: "%.0f%% of the screen  ·  %.0f px", e.rect.width * 100, px),
                     in: r)
        case .widget(let i):
            guard i < model.widgets.count else { return }
            let size = model.widgets[i].size
            let px = size.pixels(on: screen)
            drawPill("\(size.name)  ·  \(size.cells.across) × \(size.cells.down)",
                     sub: String(format: "%.0f × %.0f px", px.width, px.height), in: r)
        case nil:
            return
        }
    }

    /// Grips. Eight for the dock, whose extent is the thing that needs fixing;
    /// four inert corner pips for a widget, which says "this one is selected" in
    /// the vocabulary a rectangle editor uses without promising a resize that
    /// four fixed presets cannot honour.
    private func drawHandles(_ r: NSRect, resizable: Bool, colour: NSColor) {
        colour.setFill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        for pt in resizable ? handlePoints(r) : cornerPoints(r) {
            let d = NSRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
            let dot = NSBezierPath(ovalIn: d)
            dot.fill()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func handlePoints(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.minX, y: r.midY), NSPoint(x: r.maxX, y: r.midY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)]
    }

    private func cornerPoints(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)]
    }

    private func drawDragHalo(_ r: NSRect, radius: CGFloat, colour: NSColor) {
        for (inset, alpha, width) in [(CGFloat(14), CGFloat(0.16), CGFloat(8)),
                                      (CGFloat(6), CGFloat(0.5), CGFloat(3))] {
            let halo = continuousRoundedRect(r.insetBy(dx: -inset, dy: -inset),
                                             radius: radius + inset)
            colour.withAlphaComponent(alpha).setStroke()
            halo.lineWidth = width
            halo.stroke()
        }
    }

    private func drawPill(_ title: String, sub: String, in r: NSRect) {
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
        guard r.width > 12, r.height > 12 else { return }
        // Centred, and never drawn outside the rectangle it belongs to — a small
        // widget is 155pt square and the pill has to live inside that.
        let pill = NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
        t.draw(at: NSPoint(x: pill.midX - ts.width / 2, y: pill.minY + 4))
        s.draw(at: NSPoint(x: pill.midX - ss.width / 2, y: pill.minY + 4 + ts.height))
        NSGraphicsContext.restoreGraphicsState()
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

        guard let preview = pending else { return }
        let r = toView(model.rect(of: preview))
        let path = continuousRoundedRect(r, radius: preview.size.cornerRadius)
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 3
        path.stroke()
        drawHandles(r, resizable: false, colour: .controlAccentColor)
        let px = preview.size.pixels(on: screen)
        drawPill("\(preview.size.name)  ·  \(preview.size.cells.across) × \(preview.size.cells.down)",
                 sub: String(format: "%.0f × %.0f px", px.width, px.height), in: r)
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
                let x = g.value * bounds.width
                p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x, y: bounds.height))
            } else {
                let y = g.value * bounds.height
                p.move(to: NSPoint(x: 0, y: y)); p.line(to: NSPoint(x: bounds.width, y: y))
            }
            p.lineWidth = 1
            p.setLineDash([6, 4], count: 2, phase: 0)
            p.stroke()
        }
    }

    // MARK: - Creating

    /// The placement a drag from `anchor` to `current` produces, in fractions.
    ///
    /// The corner under the mouse when the button went down stays exactly where
    /// it is, and the snapped size grows away from it in whichever direction the
    /// drag went. Anchoring on the centre instead would make the rectangle creep
    /// out from under the pointer as the preset changed mid-drag.
    private func creation(anchor: CGPoint, current: CGPoint) -> WidgetPlacement {
        let drawn = CGSize(width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
        let size = DesktopWidgetSize.nearest(to: drawn)
        let s = model.fractionalSize(size)
        let originX = current.x >= anchor.x ? anchor.x : anchor.x - s.width * bounds.width
        let originY = current.y >= anchor.y ? anchor.y : anchor.y - s.height * bounds.height
        let frac = toFrac(NSPoint(x: originX, y: originY))
        return WidgetPlacement(size: size,
                               centre: CGPoint(x: frac.x + s.width / 2, y: frac.y + s.height / 2))
    }

    // MARK: - Snapping

    private func apply(_ snap: PlacementModel.Snap) {
        guides = snap.guides
        // `.alignment` on the transition IN and never per frame, the same rule
        // and for the same reason as the miniature: a drag parked on a guide
        // should click once, not sixty times a second.
        if !snap.names.subtracting(engaged).isEmpty { Haptics.alignment() }
        engaged = snap.names
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let f = toFrac(p)
        guides.removeAll(); engaged.removeAll(); pending = nil

        // A handle of the current selection wins over whatever is under it.
        if model.selection == .dock, let d = model.dock {
            let vr = toView(d)
            for (i, hp) in handlePoints(vr).enumerated()
            where NSRect(x: hp.x - 12, y: hp.y - 12, width: 24, height: 24).contains(p) {
                drag = .resizing(ref: .dock, handle: i, start: f, rect: d)
                model.dragging = .dock
                return
            }
        }

        if let ref = model.hit(f), let r = model.rect(of: ref) {
            // A second click on a placed widget steps it round the four sizes.
            // It is the repair for the one case classification gets wrong — a
            // rectangle drawn between two presets — and it beats deleting and
            // redrawing to change your mind.
            if event.clickCount == 2, case .widget(let i) = ref {
                model.selection = ref
                model.cycleSize(i)
                Haptics.level()
                drag = .none
                model.commit()
                return
            }
            model.selection = ref
            drag = .moving(ref: ref, grab: CGSize(width: f.x - r.minX, height: f.y - r.minY))
            model.dragging = ref
            return
        }
        model.selection = nil
        drag = .creating(anchor: p, current: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let f = toFrac(p)
        switch drag {
        case .none:
            return

        case .creating(let anchor, _):
            drag = .creating(anchor: anchor, current: p)
            // Below the threshold this is still a click on its way to being a
            // click, so there is nothing to preview and nothing to buzz about.
            let small = abs(p.x - anchor.x) < minDrag && abs(p.y - anchor.y) < minDrag
            guides.removeAll()
            if small {
                pending = nil
            } else {
                let made = model.clamped(creation(anchor: anchor, current: p))
                let snap = model.snapping(model.rect(of: made), moving: nil,
                                          tolerance: snapTolerance)
                apply(snap)
                pending = WidgetPlacement(size: made.size,
                                          centre: CGPoint(x: snap.rect.midX, y: snap.rect.midY))
            }

        case .moving(let ref, let grab):
            guard let r0 = model.rect(of: ref) else { return }
            // Clamp on to the screen BEFORE snapping, never after: a clamp
            // applied afterwards slides the rectangle back off the guide it just
            // caught, and then the dashed line is no longer touching the frame
            // the user is aiming with. Every target is inside the screen and a
            // snap moves at most one tolerance, so this order cannot let
            // anything escape.
            let moved = model.clamped(CGRect(x: f.x - grab.width, y: f.y - grab.height,
                                             width: r0.width, height: r0.height))
            let snap = model.snapping(moved, moving: ref, tolerance: snapTolerance)
            apply(snap)
            model.write(snap.rect, to: ref)

        case .resizing(let ref, let handle, let start, let rect):
            resize(ref: ref, handle: handle, from: start, to: f, rect: rect)
        }
        needsDisplay = true
    }

    /// Pull one edge of the dock, leaving the opposite edge where it is.
    private func resize(ref: PlacementModel.Ref, handle: Int,
                        from start: CGPoint, to now: CGPoint, rect: CGRect) {
        let dx = now.x - start.x, dy = now.y - start.y
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        // Which edges this handle owns. 0,3,5 are the left column; 0,1,2 the top
        // row; and so on round the eight.
        let movesLeft = handle == 0 || handle == 3 || handle == 5
        let movesRight = handle == 2 || handle == 4 || handle == 7
        let movesTop = handle <= 2
        let movesBottom = handle >= 5
        if movesLeft { minX += dx }
        if movesRight { maxX += dx }
        if movesTop { minY += dy }
        if movesBottom { maxY += dy }

        var snap = PlacementModel.Snap(rect: .zero)
        let tol = snapTolerance
        if movesLeft {
            minX = model.snappingEdge(minX, vertical: true, moving: ref,
                                      tolerance: tol.width, into: &snap)
        }
        if movesRight {
            maxX = model.snappingEdge(maxX, vertical: true, moving: ref,
                                      tolerance: tol.width, into: &snap)
        }
        if movesTop {
            minY = model.snappingEdge(minY, vertical: false, moving: ref,
                                      tolerance: tol.height, into: &snap)
        }
        if movesBottom {
            maxY = model.snappingEdge(maxY, vertical: false, moving: ref,
                                      tolerance: tol.height, into: &snap)
        }
        apply(snap)

        if maxX - minX < minDockSize {
            if movesLeft { minX = maxX - minDockSize } else { maxX = minX + minDockSize }
        }
        if maxY - minY < minDockSize {
            if movesTop { minY = maxY - minDockSize } else { maxY = minY + minDockSize }
        }
        model.write(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), to: ref)
    }

    override func mouseUp(with event: NSEvent) {
        var changed = false
        switch drag {
        case .none:
            break
        case .creating:
            // No pending placement means the drag never got past the threshold:
            // a click, and the user was dismissing the selection.
            guard let made = pending else { break }
            model.addWidget(made)
            Haptics.level()
            onChange?()
            changed = true
        case .moving, .resizing:
            changed = true
        }
        drag = .none
        pending = nil
        guides.removeAll()
        engaged.removeAll()
        model.dragging = nil
        needsDisplay = true
        if changed { model.commit() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Three speeds, matching the miniature: ⌥ a point at a time for the last
        // hair of alignment, plain a few, ⇧ a stride.
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

    /// Points in, fractions out — the keyboard's units are the screen's.
    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard let ref = model.selection, let r = model.rect(of: ref) else { return }
        let moved = model.clamped(r.offsetBy(dx: dx / max(1, bounds.width),
                                             dy: dy / max(1, bounds.height)))
        guides.removeAll()
        model.write(moved, to: ref)
        needsDisplay = true
        model.commit()
    }

    private func cycleSelection() {
        let all = model.cycleOrder
        guard !all.isEmpty else { return }
        guard let ref = model.selection, let i = all.firstIndex(of: ref) else {
            model.selection = all[0]; return
        }
        model.selection = all[(i + 1) % all.count]
        Haptics.alignment()
    }

    private func cycleSize() {
        guard case .widget(let i) = model.selection else { return }
        model.cycleSize(i)
        Haptics.level()
        model.commit()
    }
}

// MARK: - The window

/// A full-screen sheet of glass you place your desktop furniture on.
///
/// One at a time, held by a static reference for as long as it is on screen: the
/// caller gets a completion and nothing to retain, and there is no way to end up
/// with two overlays fighting over the same model.
final class WidgetSetupOverlay: NSObject, NSWindowDelegate {

    private static var current: WidgetSetupOverlay?

    /// Whether one is up. The pane uses this to avoid stacking a second.
    static var isPresented: Bool { current != nil }

    private let window: NSWindow
    private let canvas: WidgetSetupCanvas
    private let model: PlacementModel
    private let completion: (Bool) -> Void
    private let countLabel = NSTextField(labelWithString: "")
    private let hud = NSVisualEffectView()
    private var finished = false

    /// Everything the model held when this opened, so Cancel can put it back.
    ///
    /// Edits go STRAIGHT into the shared model rather than into a private copy
    /// handed back at the end, because the pane's miniature has to follow them
    /// live — that is the point of there being one model. Cancel therefore
    /// cannot mean "discard my copy"; it means "restore the snapshot", which is
    /// the same promise from the user's side.
    private let snapshot: (widgets: [WidgetPlacement], dock: CGRect?)

    /// Put the overlay up. `completion` is called with true if the user saved.
    ///
    /// One screen: `Config.widgets` are fractions with no display attached, so
    /// they are applied to every screen the app draws on (the same property that
    /// makes `Config.dockRect` dangerous to write speculatively). Marking them on
    /// the main display and letting them scale is the honest reading of what is
    /// stored; a per-display version needs a per-display config first.
    static func present(screen: NSScreen? = nil,
                        model: PlacementModel,
                        completion: @escaping (Bool) -> Void) {
        guard current == nil, let target = screen ?? NSScreen.main else {
            completion(false)
            return
        }
        current = WidgetSetupOverlay(screen: target, model: model, completion: completion)
    }

    private init(screen: NSScreen, model: PlacementModel,
                 completion: @escaping (Bool) -> Void) {
        self.completion = completion
        self.model = model
        // The overlay is drawn at 1:1 with THIS screen, so the presets have to
        // be measured against it too. A model built while a different display
        // was main would otherwise draw 329pt widgets at some other width.
        model.screenPoints = screen.frame.size
        snapshot = (model.widgets, model.dock)
        canvas = WidgetSetupCanvas(screen: screen, model: model)

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

        refreshCount()

        // Activation, not key-window changes, decides click-through: moving key
        // to another window OF OURS — the settings window floating above this
        // one — is not the user reaching past the overlay.
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

        let title = NSTextField(labelWithString: "Where are your widgets and your dock?")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let hint = NSTextField(wrappingLabelWithString:
            "Drag a rectangle over each widget — it snaps to the nearest real widget size. Drag a "
          + "placed one to move it, double-click or press Space to change its size, ⌫ to remove "
          + "it. The teal rectangle is your dock: macOS only tells us how THICK it is, so pull "
          + "its handles out to the length it really is. Everything you do here also moves on the "
          + "little screen in Settings. Click any other app and this sheet lets your clicks "
          + "through; come back with the Elemental menu bar icon.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 460
        // Fixed rather than intrinsic, so the panel is one stable width and the
        // button row below can be tied to it without the two fighting.
        hint.widthAnchor.constraint(equalToConstant: 460).isActive = true

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor

        let clear = NSButton(title: "Clear Widgets", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Done", target: self, action: #selector(save))
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
        // with an unclickable Done button.
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
        // Ordered front but NOT made key: the settings window floats above this
        // one so its miniature can be worked at the same time, and stealing key
        // back from it on every activation would take the user's clicks away
        // from whichever of the two they had chosen.
        window.orderFront(nil)
    }

    @objc private func appDeactivated() {
        window.ignoresMouseEvents = true
        canvas.isPassive = true
        // Faded rather than hidden: the overlay is still holding unsaved work,
        // and a panel that vanished would read as the setup having been closed.
        hud.alphaValue = 0.45
    }

    // MARK: - Finishing

    @objc private func save() { finish(saved: true) }

    @objc private func cancel() {
        model.setWidgets(snapshot.widgets)
        model.dock = snapshot.dock
        model.selection = nil
        model.commit()
        finish(saved: false)
    }

    @objc private func clearAll() { canvas.removeAll() }

    func windowWillClose(_ notification: Notification) { finish(saved: false) }

    private func finish(saved: Bool) {
        guard !finished else { return }
        finished = true
        NotificationCenter.default.removeObserver(self)
        window.delegate = nil
        model.dragging = nil
        window.orderOut(nil)
        // `current` is the only strong reference to this object, so clearing it
        // can deallocate self — potentially before the completion has run, since
        // a method does not retain its own receiver. Hand the closure out to a
        // local first and hold self across the call.
        let hand = completion
        WidgetSetupOverlay.current = nil
        withExtendedLifetime(self) { hand(saved) }
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
