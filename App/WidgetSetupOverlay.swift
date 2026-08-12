//  WidgetSetupOverlay.swift — point at your furniture instead of guessing at it.
//
//  macOS publishes no API for where desktop widgets are. Everything else the
//  engine needs to collide with, it can ask the system for: the menu bar and the
//  dock's THICKNESS come out of `NSScreen.visibleFrame` exactly. Widgets come
//  from nowhere, and the dock's extent along its edge is a guess made from
//  com.apple.dock that measures about a quarter short.
//
//  This is the direct way round, and it is the user's idea: stop inferring, and
//  let them SHOW us. A translucent sheet over the real desktop, drag a box round
//  each widget, pull the dock out to its real length, done.
//
//  ---- One editor, two windows
//
//  This is not a separate editor from the miniature in the Elements pane. Both
//  are views onto one `PlacementModel` (see Placements.swift): the same
//  placements, the same snapping rules, the same resize solver, the same commit
//  path. The settings window deliberately stays up while this is on screen,
//  floating above it, so a widget dragged here moves on the miniature under your
//  eyes and a widget dragged there lights up here — `PlacementModel.dragging` is
//  what carries that, and every drag sets it.
//
//  ---- Sizes: magnets, not a cage
//
//  A freehand rectangle drawn over a widget is a worse measurement than a
//  preset, because a hand is not a ruler and nobody drags to the pixel. macOS
//  has exactly four desktop widget sizes and they are fixed numbers of points,
//  so a rubber-banded rectangle is CLASSIFIED to the nearest of them: drag
//  something roughly 300 by 150 and you get a medium widget, exactly 329 × 155,
//  which is exactly what is on the screen underneath it.
//
//  But it is a magnet and not a cage, because this is a description of what is
//  actually there rather than of what the system offers. Every placement can be
//  resized by its handles to any size at all; the four presets simply pull hard
//  as a resize passes them, one axis at a time, and the readout says plainly
//  whether what you have is "Medium, 4 × 2" or "Custom, 340 × 160 pt". Hold ⌥
//  while drawing to keep exactly the rectangle you drew.
//
//  The dock never gets the size magnets — it has no presets — but it does get
//  the derived rectangle `Furniture.desktop` computed as a snap target, so
//  correcting the automatic answer starts from the automatic answer.
//
//  ---- Suggestions
//
//  Opening this captures the screen and runs `FurnitureDetector` over it, every
//  time. The result is drawn as a dashed, dimmer layer that is taken or dropped
//  a rectangle at a time and never overwrites anything already placed. See
//  DesktopSuggestions.swift for why it is a suggestion and not an answer, and
//  for what happens when Screen Recording is off.
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

    /// Fires whenever the placement or suggestion count changes, for the HUD.
    var onChange: (() -> Void)?

    // ---- drag state

    private enum Drag {
        case none
        /// Rubber-banding a new rectangle. `anchor` is where the mouse went
        /// down and is the corner that stays put when the size snaps.
        /// `freehand` is ⌥ held: keep exactly what was drawn.
        case creating(anchor: CGPoint, current: CGPoint, freehand: Bool)
        /// Moving an existing one. `grab` is the pointer's offset inside it,
        /// in fractions.
        case moving(ref: PlacementModel.Ref, grab: CGSize)
        /// Pulling one of its handles, indexed as `ResizeHandle` numbers them.
        case resizing(ref: PlacementModel.Ref, handle: Int, start: CGPoint, rect: CGRect)
    }
    private var drag: Drag = .none

    /// Exactly the rectangle a mouse-up would commit, in fractions, kept up to
    /// date by the drag rather than worked out again in `draw`.
    ///
    /// Two reasons it lives here and not in the drawing. Snapping fires haptics
    /// and records guides, and neither belongs on a redraw — a window resize
    /// would buzz. And the preview has to be the SAME rectangle that gets
    /// committed, snap included: a preview that showed the unsnapped position
    /// would jump the moment the button came up, which is the one thing a
    /// preview exists to prevent.
    private var pending: CGRect?

    /// Below this, in points, a drag was a click. The smallest preset is 155pt
    /// across, so there is no risk of confusing a deliberate small widget with a
    /// stray twitch on the way to selecting one.
    private let minDrag: CGFloat = 22

    /// Smallest anything may be pulled to, as a fraction of the screen.
    private let minSize: CGFloat = 0.02

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
    private func radius(_ points: CGFloat) -> CGFloat {
        points * (bounds.width / max(1, model.screenPoints.width))
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
            wash.append(continuousRoundedRect(toView(e.rect), radius: radius(e.radiusPoints)))
        }
        for s in model.suggestions {
            wash.append(continuousRoundedRect(toView(s.rect), radius: suggestionRadius(s)))
        }
        if let p = pending {
            wash.append(continuousRoundedRect(toView(p),
                                              radius: radius(model.cornerRadiusPoints(for: p))))
        }
        NSColor.black.withAlphaComponent(isPassive ? 0.22 : 0.44).setFill()
        wash.fill()

        drawGuides()
        drawSuggestions()

        for e in model.elements where e.editable { draw(e) }

        if case .creating(let anchor, let current, _) = drag { drawCreation(anchor, current) }

        if model.widgets.isEmpty, model.suggestions.isEmpty, case .none = drag { drawEmptyHint() }

        drawMeasurement()
    }

    private func draw(_ e: PlacementModel.Element) {
        let r = toView(e.rect)
        let rad = radius(e.radiusPoints)
        let selected = e.ref != nil && model.selection == e.ref
        let path = continuousRoundedRect(r, radius: rad)
        // The dock is a different KIND of thing from a widget — system-owned
        // where they are yours, free where they have presets — so it is drawn in
        // a different colour rather than being made to look like a big widget.
        let accent = e.ref == .dock ? NSColor.systemTeal : NSColor.controlAccentColor
        accent.withAlphaComponent(selected ? 0.22 : 0.12).setFill()
        path.fill()
        (selected ? accent : accent.withAlphaComponent(0.75)).setStroke()
        path.lineWidth = selected ? 3 : 2
        path.stroke()

        // The live link with the pane's miniature: whatever is under the hand
        // right now glows here too, even when the hand is over there.
        if let ref = e.ref, model.dragging == ref { drawDragHalo(r, radius: rad, colour: accent) }

        if selected { drawHandles(r, indices: e.handles, colour: accent) }

        drawLabel(for: e, in: r)
    }

    private func drawLabel(for e: PlacementModel.Element, in r: NSRect) {
        switch e.ref {
        case .dock:
            let p = model.pointSize(of: e.rect)
            drawPill(e.label,
                     sub: String(format: "%.0f × %.0f pt  ·  %.1f%% of the screen",
                                 p.width, p.height, e.rect.width * 100), in: r)
        case .widget(let i):
            guard i < model.widgets.count else { return }
            let p = model.pointSize(of: e.rect)
            drawPill(model.sizeDescription(of: e.rect),
                     sub: String(format: "%.0f × %.0f pt  ·  %.0f × %.0f px",
                                 p.width, p.height,
                                 p.width * screen.backingScaleFactor,
                                 p.height * screen.backingScaleFactor), in: r)
        case nil:
            return
        }
    }

    /// Grips. Eight round a widget, which can be any size; the four mid-edge
    /// ones for the dock, so that every dock drag changes exactly one edge and a
    /// length can be set without a stray vertical wobble changing its thickness.
    private func drawHandles(_ r: NSRect, indices: [Int], colour: NSColor) {
        colour.setFill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        for i in indices {
            let pt = ResizeHandle.point(i, in: r)
            let d = NSRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
            let dot = NSBezierPath(ovalIn: d)
            dot.fill()
            dot.lineWidth = 1.5
            dot.stroke()
        }
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

    private func drawPill(_ title: String, sub: String, in r: NSRect, clip: Bool = true) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.78),
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
        if clip { NSBezierPath(rect: r).addClip() }
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
        t.draw(at: NSPoint(x: pill.midX - ts.width / 2, y: pill.minY + 4))
        s.draw(at: NSPoint(x: pill.midX - ss.width / 2, y: pill.minY + 4 + ts.height))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The numbers, while a rectangle is being moved or pulled.
    ///
    /// The dock is the reason this exists. Its thickness is known exactly and
    /// its length is not, so "make it precisely this long" is a real task, and a
    /// rectangle you can only judge by eye against a dock that is drawn
    /// underneath it is not a way to do it. Both edges in points, the size in
    /// points, and the same figures as percentages — the fractions are what is
    /// actually stored, and what survives a change of resolution.
    private func drawMeasurement() {
        guard let ref = model.dragging, let f = model.rect(of: ref) else { return }
        let r = toView(f)
        let p = model.pointSize(of: f)
        let head: String
        switch ref {
        case .dock:
            head = String(format: "%.0f × %.0f pt", p.width, p.height)
        case .widget:
            head = model.sizeDescription(of: f)
        }
        let body = String(format: "left %.0f · top %.0f · right %.0f · bottom %.0f pt   "
                                + "(%.1f%%, %.1f%%, %.1f%% × %.1f%%)",
                          f.minX * model.screenPoints.width,
                          f.minY * model.screenPoints.height,
                          f.maxX * model.screenPoints.width,
                          f.maxY * model.screenPoints.height,
                          f.minX * 100, f.minY * 100, f.width * 100, f.height * 100)

        // Above the rectangle, or below it when there is no room above — the
        // numbers must never sit on top of the edge being aimed.
        let band: NSRect
        if r.minY > 58 {
            band = NSRect(x: r.minX, y: r.minY - 56, width: max(r.width, 320), height: 46)
        } else {
            band = NSRect(x: r.minX, y: min(bounds.height - 56, r.maxY + 10),
                          width: max(r.width, 320), height: 46)
        }
        drawPill(head, sub: body, in: band, clip: false)
    }

    // MARK: - Suggestions

    private func suggestionRadius(_ s: PlacementModel.Suggestion) -> CGFloat {
        switch s.kind {
        case .dock:
            let v = toView(s.rect)
            return min(18, min(v.width, v.height) / 2)
        case .widget:
            return radius(model.cornerRadiusPoints(for: s.rect))
        }
    }

    /// Dashed, dimmer, and labelled with what to do about it.
    ///
    /// Provisional has to be legible at a glance, because the whole bargain is
    /// that the user can ignore the lot. Nothing about a suggestion looks like
    /// something they placed: different colour, dashed outline, thinner stroke,
    /// and an instruction inside it rather than a measurement.
    private func drawSuggestions() {
        for s in model.suggestions {
            let r = toView(s.rect)
            let path = continuousRoundedRect(r, radius: suggestionRadius(s))
            NSColor.systemPink.withAlphaComponent(0.10).setFill()
            path.fill()
            NSColor.systemPink.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            path.setLineDash([7, 5], count: 2, phase: 0)
            path.stroke()
            drawPill(s.kind == .dock ? "Dock?" : "Widget?",
                     sub: "click to keep  ·  ⌥-click to dismiss", in: r)
        }
    }

    // MARK: - Creating

    /// The rectangle a drag from `anchor` to `current` produces, in fractions.
    ///
    /// The corner under the mouse when the button went down stays exactly where
    /// it is, and the snapped size grows away from it in whichever direction the
    /// drag went. Anchoring on the centre instead would make the rectangle creep
    /// out from under the pointer as the preset changed mid-drag.
    private func creation(anchor: CGPoint, current: CGPoint, freehand: Bool) -> CGRect {
        let a = toFrac(anchor), c = toFrac(current)
        let raw = CGRect(x: min(a.x, c.x), y: min(a.y, c.y),
                         width: abs(c.x - a.x), height: abs(c.y - a.y))
        guard !freehand else { return raw }
        let s = model.fractionalSize(DesktopWidgetSize.nearest(to: model.pointSize(of: raw)))
        return CGRect(x: c.x >= a.x ? a.x : a.x - s.width,
                      y: c.y >= a.y ? a.y : a.y - s.height,
                      width: s.width, height: s.height)
    }

    /// The live rubber band: what the hand is doing, faintly, with the size it
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
        let r = toView(preview)
        let path = continuousRoundedRect(r, radius: radius(model.cornerRadiusPoints(for: preview)))
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 3
        path.stroke()
        drawHandles(r, indices: ResizeHandle.all, colour: .controlAccentColor)
        let p = model.pointSize(of: preview)
        drawPill(model.sizeDescription(of: preview),
                 sub: String(format: "%.0f × %.0f pt", p.width, p.height), in: r)
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
        NSColor.systemYellow.withAlphaComponent(0.9).setStroke()
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

    // MARK: - Snapping

    private func apply(_ snap: PlacementModel.Snap) {
        guides = snap.guides
        // `.alignment` on the transition IN and never per frame, the same rule
        // and for the same reason as the miniature: a drag parked on a guide
        // should click once, not sixty times a second. A preset dimension
        // catching counts as a line for this purpose — it is the same "you have
        // landed on something" that the user is feeling for.
        if !snap.names.subtracting(engaged).isEmpty { Haptics.alignment() }
        engaged = snap.names
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let f = toFrac(p)
        let option = event.modifierFlags.contains(.option)
        guides.removeAll(); engaged.removeAll(); pending = nil

        // A suggestion is taken or dropped with one click, before anything else
        // is considered — it is drawn over the desktop and under nothing.
        if let s = model.suggestion(at: f) {
            if option {
                model.dismissSuggestion(s.id)
            } else {
                model.acceptSuggestion(s.id)
                Haptics.level()
            }
            onChange?()
            drag = .none
            return
        }

        // A handle of the current selection wins over whatever is under it.
        if let ref = model.selection, let r = model.rect(of: ref),
           let e = model.elements.first(where: { $0.ref == ref }) {
            let vr = toView(r)
            for i in e.handles {
                let hp = ResizeHandle.point(i, in: vr)
                guard NSRect(x: hp.x - 12, y: hp.y - 12, width: 24, height: 24).contains(p)
                else { continue }
                drag = .resizing(ref: ref, handle: i, start: f, rect: r)
                model.dragging = ref
                return
            }
        }

        if let ref = model.hit(f), let r = model.rect(of: ref) {
            // A second click on a placed widget steps it round the four presets.
            // Still worth having next to free resizing: "make this one exactly a
            // medium" is one keystroke rather than two axes of dragging until
            // both magnets catch at once.
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
        drag = .creating(anchor: p, current: p, freehand: option)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let f = toFrac(p)
        switch drag {
        case .none:
            return

        case .creating(let anchor, _, let freehand):
            drag = .creating(anchor: anchor, current: p, freehand: freehand)
            // Below the threshold this is still a click on its way to being a
            // click, so there is nothing to preview and nothing to buzz about.
            let small = abs(p.x - anchor.x) < minDrag && abs(p.y - anchor.y) < minDrag
            guides.removeAll()
            if small {
                pending = nil
            } else {
                let made = model.clamped(creation(anchor: anchor, current: p, freehand: freehand))
                let snap = model.snapping(made, moving: nil, tolerance: snapTolerance)
                apply(snap)
                pending = snap.rect
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
            // Every rule — which edges the handle owns, the positional guides,
            // the preset-dimension magnets, the minimum size — lives in the
            // model, so this and the pane's miniature resize identically.
            let snap = model.resizing(rect, handle: handle,
                                      dx: f.x - start.x, dy: f.y - start.y,
                                      ref: ref, tolerance: snapTolerance, minimum: minSize,
                                      presetMagnets: ref != .dock)
            apply(snap)
            model.write(snap.rect, to: ref)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        var changed = false
        switch drag {
        case .none:
            break
        case .creating:
            // No pending rectangle means the drag never got past the threshold:
            // a click, and the user was dismissing the selection.
            guard let made = pending else { break }
            model.addWidget(WidgetPlacement(rect: made))
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
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let hud = NSVisualEffectView()
    private var suggestionRow: NSStackView!
    private var permissionButton: NSButton!
    private var finished = false

    /// Everything the model held when this opened, so Cancel can put it back.
    ///
    /// Edits go STRAIGHT into the shared model rather than into a private copy
    /// handed back at the end, because the pane's miniature has to follow them
    /// live — that is the point of there being one model. Cancel therefore
    /// cannot mean "discard my copy"; it means "restore the snapshot", which is
    /// the same promise from the user's side.
    private let snapshot: (widgets: [WidgetPlacement], dock: CGRect?, dockPlaced: Bool)

    /// Put the overlay up. `completion` is called with true if the user saved.
    ///
    /// `config` is only needed for the reference render detection compares
    /// against — see DesktopSuggestions.swift.
    ///
    /// One screen: `Config.widgets` are fractions with no display attached, so
    /// they are applied to every screen the app draws on (the same property that
    /// makes `Config.dockRect` dangerous to write speculatively). Marking them on
    /// the main display and letting them scale is the honest reading of what is
    /// stored; a per-display version needs a per-display config first.
    static func present(screen: NSScreen? = nil,
                        model: PlacementModel,
                        config: Config,
                        completion: @escaping (Bool) -> Void) {
        guard current == nil, let target = screen ?? NSScreen.main else {
            completion(false)
            return
        }
        current = WidgetSetupOverlay(screen: target, model: model, config: config,
                                     completion: completion)
    }

    private init(screen: NSScreen, model: PlacementModel, config: Config,
                 completion: @escaping (Bool) -> Void) {
        self.completion = completion
        self.model = model
        // The overlay is drawn at 1:1 with THIS screen, so the presets have to
        // be measured against it too. A model built while a different display
        // was main would otherwise draw 329pt widgets at some other width.
        model.screenPoints = screen.frame.size
        snapshot = (model.widgets, model.dock, model.dockIsUserPlaced)
        canvas = WidgetSetupCanvas(screen: screen, model: model)

        window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
        // ABOVE THE DOCK, and below the menu bar.
        //
        // `.floating` is window level 3 and the macOS Dock is level 20, so the
        // Dock drew straight over this overlay. That is not a cosmetic layering
        // problem: the dock rect is at the bottom of the screen and its resize
        // handles sit ON its edges, so every one of them was underneath the real
        // Dock and could not be clicked at all. The one piece of furniture whose
        // derived extent is known to be wrong was the one piece you could not
        // reach in to correct.
        //
        // 21 clears the Dock and stays under `.mainMenu` at 24, which preserves
        // the escape route the level was chosen for in the first place: Elemental
        // is LSUIElement with no Cmd-Tab entry, so once clicks pass through, the
        // menu bar item is the only way back in and an overlay covering it would
        // strand the user.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
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

        // The suggestion layer is not carried between openings. Detection is
        // cheap and the desktop moves, so a rectangle offered five minutes ago
        // is a worse guess than one offered now.
        model.dismissAllSuggestions()
        model.suggestionNote = "Looking at your screen…"
        refreshCount()

        model.observe(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .suggestions, .geometry: self.refreshCount()
            case .selection, .dragging, .commit: break
            }
        }

        // Activation, not key-window changes, decides click-through: moving key
        // to another window OF OURS — the settings window floating above this
        // one — is not the user reaching past the overlay.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appActivated),
                       name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDeactivated),
                       name: NSApplication.didResignActiveNotification, object: nil)
        // A permission prompt cannot be answered through a full-screen modal
        // overlay: the system dialog needs the Settings pane behind it to be
        // reachable afterwards, and this covers the whole display. So save what
        // is here and get out of the way rather than leaving the user to work
        // out why nothing responds. Saving rather than cancelling is deliberate
        // — they were placing furniture, not abandoning it, and losing the work
        // to a permission dialog would be its own bug.
        nc.addObserver(self, selector: #selector(permissionPromptWillShow),
                       name: .elementalPermissionPrompt, object: nil)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)

        // AFTER the window is up, so the overlay never waits on a capture. Our
        // own windows — this one and the settings window — are excluded from the
        // shot by the content filter, so there is nothing to hide first.
        DesktopSuggestions.run(screen: screen, config: config) { [weak self] result in
            guard let self, !self.finished else { return }
            self.model.suggestionNote = result.note
            self.model.setSuggestions(widgets: result.widgets, dock: result.dock)
            self.refreshCount()
        }
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
            "Drag a rectangle over each widget — it snaps to the nearest real widget size, and ⌥ "
          + "while dragging keeps exactly what you drew. Take a handle to resize one to any size "
          + "at all; the four macOS sizes pull hard as you pass them. Space steps through the "
          + "presets, ⌫ removes one. The teal rectangle is your dock: macOS only reports how "
          + "THICK it is, so pull its end handles out to the length it really is — the numbers "
          + "above it are live. Everything here also moves on the little screen in Settings.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 520
        // Fixed rather than intrinsic, so the panel is one stable width and the
        // button rows below can be tied to it without the two fighting.
        hint.widthAnchor.constraint(equalToConstant: 520).isActive = true

        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.preferredMaxLayoutWidth = 520

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor

        let keepAll = NSButton(title: "Keep All Suggestions", target: self,
                               action: #selector(keepAllSuggestions))
        keepAll.bezelStyle = .rounded
        let dropAll = NSButton(title: "Dismiss Suggestions", target: self,
                               action: #selector(dismissAllSuggestions))
        dropAll.bezelStyle = .rounded
        permissionButton = NSButton(title: "Turn On Screen Recording…", target: self,
                                    action: #selector(askForScreenRecording))
        permissionButton.bezelStyle = .rounded
        permissionButton.isHidden = ScreenRecording.isGranted

        let suggestionSpacer = NSView()
        suggestionSpacer.translatesAutoresizingMaskIntoConstraints = false
        suggestionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        suggestionRow = NSStackView(views: [permissionButton, suggestionSpacer, keepAll, dropAll])
        suggestionRow.spacing = 8
        suggestionRow.alignment = .centerY

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

        let column = NSStackView(views: [title, hint, noteLabel, suggestionRow, buttons])
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
            suggestionRow.widthAnchor.constraint(equalTo: hint.widthAnchor),
            hud.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                        constant: -(dockInset + 24)),
        ])
    }

    private func refreshCount() {
        let n = canvas.count
        let s = model.suggestions.count
        var parts: [String] = [n == 0 ? "nothing placed" : "\(n) widget\(n == 1 ? "" : "s") placed"]
        if s > 0 { parts.append("\(s) suggested") }
        countLabel.stringValue = parts.joined(separator: "  ·  ")
        noteLabel.stringValue = model.suggestionNote ?? ""
        noteLabel.isHidden = noteLabel.stringValue.isEmpty
        // The suggestion row only earns its space when there is something to
        // accept, or a permission to turn on that would produce some.
        suggestionRow.isHidden = s == 0 && ScreenRecording.isGranted
        permissionButton.isHidden = ScreenRecording.isGranted
    }

    // MARK: - Click-through

    @objc private func appActivated() {
        window.ignoresMouseEvents = false      // see appDeactivated: never re-set
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
        // NOT click-through, even when we lose activation.
        //
        // This used to set `ignoresMouseEvents = true` the moment another app
        // came forward, on the reasoning that the user might want to reach the
        // desktop underneath. In practice the overlay covers the whole screen
        // while you are placing things ON that screen, so every click that fell
        // through landed on whatever happened to be behind it — Finder, a
        // browser, the desktop itself — and the first sign of it was something
        // else coming to the front, or an icon moving. You cannot place a
        // rectangle accurately on a surface that is also forwarding your clicks
        // to somebody else.
        //
        // So while setup is open the screen belongs to setup: the only things
        // that take a click are this overlay and the settings window floating
        // above it, which is where an element's own settings live. Everything
        // else is inert until Save or Cancel. The menu bar is still above us at
        // level 24 and still works, so there is always a way out.
        canvas.isPassive = true
        // Faded rather than hidden: the overlay is still holding unsaved work,
        // and a panel that vanished would read as the setup having been closed.
        hud.alphaValue = 0.45
    }

    // MARK: - Finishing

    @objc private func save() { finish(saved: true) }

    @objc private func permissionPromptWillShow() {
        guard !finished else { return }
        model.commit()
        finish(saved: true)
    }

    @objc private func cancel() {
        model.setWidgets(snapshot.widgets)
        model.dock = snapshot.dock
        model.dockIsUserPlaced = snapshot.dockPlaced
        model.selection = nil
        model.commit()
        finish(saved: false)
    }

    @objc private func clearAll() { canvas.removeAll() }

    @objc private func keepAllSuggestions() {
        model.acceptAllSuggestions()
        Haptics.level()
        refreshCount()
    }

    @objc private func dismissAllSuggestions() {
        model.dismissAllSuggestions()
        refreshCount()
    }

    @objc private func askForScreenRecording() {
        ScreenRecording.request()
        model.suggestionNote =
            "Turn Elemental on under Screen Recording, then quit and reopen it — macOS only "
          + "hands the permission to a fresh launch. Nothing here needs it: every rectangle can "
          + "be placed by hand."
        refreshCount()
    }

    func windowWillClose(_ notification: Notification) { finish(saved: false) }

    private func finish(saved: Bool) {
        guard !finished else { return }
        finished = true
        NotificationCenter.default.removeObserver(self)
        model.stopObserving(self)
        window.delegate = nil
        model.dragging = nil
        // The suggestion layer belongs to the session that produced it. Leaving
        // it behind would put dashed rectangles on the pane's miniature that
        // nothing there can accept or dismiss.
        model.dismissAllSuggestions()
        model.suggestionNote = nil
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
