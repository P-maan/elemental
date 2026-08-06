//  SettingsKit.swift — the look of the settings window.
//
//  Settings used to be one long vertical stack of `label: control` rows at a
//  single weight and a single size. Everything was equally loud, so nothing was
//  legible, and an option you did not already understand stayed that way.
//
//  This file is the vocabulary the panes are rebuilt from, borrowed from the
//  current generation of Mac customisation apps (Alcove, Raycast, CleanShot):
//
//    * a HERO at the top of each pane — a large live render of the thing being
//      configured. It is the primary content; the controls underneath serve it.
//    * CARDS. Related controls sit together on a filled rounded rectangle with
//      a quiet symbol-and-title header, and cards are separated by real space.
//    * MATERIAL behind everything, so the window reads as a Mac window rather
//      than as a form.
//    * a TYPE SCALE: headline for section titles, body for control labels,
//      caption in secondary colour for explanation.
//
//  Two rules run through all of it.
//
//  Semantic colours only — `labelColor`, `controlBackgroundColor`,
//  `separatorColor` and friends. They resolve per appearance, so light mode,
//  dark mode and the increased-contrast settings are all correct for free. A
//  hardcoded grey is right exactly once. Note that this rules out setting
//  `layer.backgroundColor` directly, since a CGColor is resolved at assignment
//  and then frozen; `NSBox.fillColor` keeps the NSColor and is re-resolved, so
//  cards are boxes.
//
//  Nothing here renders. Every thumbnail goes through `ScenePreview`, which is
//  cached, coalesced and off the main thread — see the header of
//  PreviewRenderer.swift for why that is not negotiable.

import AppKit

// MARK: - Metrics and type

enum UI {

    /// Between cards. Deliberately large: the single cheapest thing that makes a
    /// settings window feel considered is space between groups.
    static let cardGap: CGFloat = 18
    /// Between rows inside a card.
    static let rowGap: CGFloat = 10
    static let cardPadding: CGFloat = 14
    static let paneInset: CGFloat = 22
    static let corner: CGFloat = 10
    /// Fixed label column, so controls line up down the whole window.
    static let labelWidth: CGFloat = 96

    static var headline: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static var body: NSFont { .systemFont(ofSize: 12, weight: .regular) }
    static var caption: NSFont { .systemFont(ofSize: 11, weight: .regular) }
    static var value: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    /// Show or hide with a fade rather than a jump.
    ///
    /// The glass controls appear and disappear when the finish changes, and a
    /// row that simply blinks out of existence reads as a glitch. Animating
    /// `isHidden` inside a stack view needs `allowsImplicitAnimation` so the
    /// relayout the stack does in response is animated too.
    static func setHidden(_ views: [NSView], _ hidden: Bool, animated: Bool = true) {
        let changing = views.filter { $0.isHidden != hidden }
        guard !changing.isEmpty else { return }
        guard animated, views.first?.window != nil else {
            for v in changing { v.isHidden = hidden; v.alphaValue = hidden ? 0 : 1 }
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for v in changing {
                v.animator().alphaValue = hidden ? 0 : 1
                v.animator().isHidden = hidden
            }
            views.first?.superview?.layoutSubtreeIfNeeded()
        }
    }
}

// MARK: - Text

func headlineLabel(_ s: String) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    f.font = UI.headline
    f.textColor = .labelColor
    return f
}

func bodyLabel(_ s: String) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    f.font = UI.body
    f.textColor = .labelColor
    return f
}

/// A view whose origin is at the TOP left.
///
/// The pane's scroll view needs one for its document view. AppKit's default
/// bottom-left origin means a document shorter than the clip view sits at the
/// bottom of it, so a short pane renders as a screenful of empty space with the
/// cards hanging off the end.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Wrap a fixed-size view in a container that centres it horizontally and
/// stretches to whatever width it is given. The hero and the desktop schematic
/// both render at a fixed size on purpose, so they need centring rather than
/// stretching.
func centred(_ v: NSView) -> NSView {
    let box = NSView()
    box.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(v)
    NSLayoutConstraint.activate([
        v.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        v.topAnchor.constraint(equalTo: box.topAnchor),
        v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        v.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor),
        v.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
    ])
    return box
}

func captionLabel(_ s: String, width: CGFloat = 460) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: s)
    f.font = UI.caption
    f.textColor = .secondaryLabelColor
    f.preferredMaxLayoutWidth = width
    f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return f
}

// MARK: - Card

/// A group of related controls on a filled rounded rectangle.
///
/// `NSBox` rather than a layer-backed `NSView` on purpose: `fillColor` and
/// `borderColor` keep their `NSColor`, so the card repaints itself correctly
/// when the system flips between light and dark. A `layer.backgroundColor` set
/// from `NSColor.controlBackgroundColor.cgColor` would freeze whichever
/// appearance happened to be current when the window was built.
final class Card: NSBox {

    /// Controls go here.
    let content = NSStackView()
    private let header = NSStackView()
    private var headerShown = false

    init(_ title: String? = nil, symbol: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        boxType = .custom
        borderType = .lineBorder
        borderWidth = 1
        cornerRadius = UI.corner
        fillColor = .controlBackgroundColor
        borderColor = .separatorColor
        titlePosition = .noTitle
        contentViewMargins = .zero

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = UI.rowGap
        content.translatesAutoresizingMaskIntoConstraints = false

        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        if let title {
            headerShown = true
            if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let iv = NSImageView()
                iv.image = img.withSymbolConfiguration(
                    .init(pointSize: 12, weight: .semibold, scale: .small))
                iv.contentTintColor = .secondaryLabelColor
                iv.widthAnchor.constraint(equalToConstant: 16).isActive = true
                header.addArrangedSubview(iv)
            }
            header.addArrangedSubview(headlineLabel(title))
        }

        let outer = NSStackView(views: headerShown ? [header, content] : [content])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.edgeInsets = NSEdgeInsets(top: UI.cardPadding, left: UI.cardPadding,
                                        bottom: UI.cardPadding, right: UI.cardPadding)

        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: host.topAnchor),
            outer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        contentView = host
        // NSBox does NOT constrain a custom contentView to itself — it expects
        // to position it with autoresizing. Assigning one that uses Auto Layout
        // and stopping there gives a box whose fitting size is (0, 0): it
        // collapses to zero height, the stack view above it packs every card at
        // the same y, and the whole pane draws on top of itself. Nothing warns
        // about it, because no constraint is actually in conflict.
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func add(_ v: NSView) -> Card { content.addArrangedSubview(v); return self }

    @discardableResult
    func add(_ vs: [NSView]) -> Card { vs.forEach { content.addArrangedSubview($0) }; return self }

    /// Explanatory text at the foot of the card, in the caption style.
    @discardableResult
    func note(_ s: String) -> Card { content.addArrangedSubview(captionLabel(s)); return self }

    /// A hairline between two groups of rows inside one card.
    @discardableResult
    func rule() -> Card {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 430).isActive = true
        content.addArrangedSubview(b)
        return self
    }
}

// MARK: - The hero

/// The large live render at the top of a pane.
///
/// Renders at a fixed pixel size whatever the window does, so the GPU cost of a
/// drag does not depend on how big the user has made the window. On a Retina
/// display the natural size is 1:1.
final class HeroPreview: NSView {

    static let pixels = ScenePreview.large
    static let points = NSSize(width: ScenePreview.large.width / 2,
                               height: ScenePreview.large.height / 2)

    private let imageView = NSImageView()
    private let placeholder = NSTextField(labelWithString: "")
    private var issued = 0
    private var shown = -1
    private(set) var spec: PreviewSpec?

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.points))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // A quiet placeholder until the first frame lands, so an empty hero
        // reads as "rendering" and not as a bug.
        let back = NSBox()
        back.boxType = .custom
        back.borderType = .noBorder
        back.fillColor = .quaternaryLabelColor
        back.cornerRadius = 12
        back.translatesAutoresizingMaskIntoConstraints = false

        placeholder.stringValue = "Rendering preview…"
        placeholder.font = UI.caption
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleAxesIndependently
        imageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(back); addSubview(placeholder); addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.points.width),
            heightAnchor.constraint(equalToConstant: Self.points.height),
            back.topAnchor.constraint(equalTo: topAnchor),
            back.leadingAnchor.constraint(equalTo: leadingAnchor),
            back.trailingAnchor.constraint(equalTo: trailingAnchor),
            back.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.image)
        setAccessibilityLabel("Live preview of the wallpaper as configured")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Cheap to call on every mouse-move of a drag: identical specs return at
    /// once, and `ScenePreview` drops every superseded request before it
    /// reaches the GPU.
    func show(_ s: PreviewSpec) {
        guard s != spec || imageView.image == nil else { return }
        spec = s
        issued += 1
        let mine = issued
        ScenePreview.shared.request(s, slot: ObjectIdentifier(self)) { [weak self] img in
            guard let self, mine >= self.shown else { return }
            self.shown = mine
            self.imageView.image = img
            self.placeholder.isHidden = true
        }
    }
}

// MARK: - Rows

/// `label   control`, with the label in a fixed column.
func formRow(_ title: String, _ control: NSView) -> NSView {
    let l = bodyLabel(title)
    l.alignment = .right
    l.textColor = .secondaryLabelColor
    l.translatesAutoresizingMaskIntoConstraints = false
    l.widthAnchor.constraint(equalToConstant: UI.labelWidth).isActive = true
    let s = NSStackView(views: [l, control])
    s.translatesAutoresizingMaskIntoConstraints = false
    s.spacing = 10
    s.alignment = .centerY
    return s
}

// MARK: - The desktop schematic
//
// The furniture-water switches are the one group in the window that cannot be
// shown with a render. The wallpaper draws behind the dock, the widgets and the
// menu bar, and which of those weather is allowed to mark is a property of the
// SCREEN, not of the scene — a 380-point thumbnail of the sky says nothing
// about it. Worse, the engine reads those switches from `Furniture.options`,
// which is global and shared with the wallpaper that is running right now;
// twiddling it to render a preview would make the real desktop flicker.
//
// So this is a drawing rather than a render: a little screen with its menu bar,
// dock and widgets, and whichever of them weather is allowed to mark lit up.
// It costs nothing, updates instantly, and answers the question the switches
// actually raise, which is "which part of my screen is that".

final class FurnitureDiagram: NSView {

    var wetDock = true { didSet { needsDisplay = true } }
    var wetWidgets = true { didSet { needsDisplay = true } }
    var wetMenuBar = false { didSet { needsDisplay = true } }
    var wetPane = true { didSet { needsDisplay = true } }
    /// 0...1, dims the highlight the way the amount sliders dim the effect.
    var furniture: CGFloat = 1 { didSet { needsDisplay = true } }
    var pane: CGFloat = 1 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 240).isActive = true
        heightAnchor.constraint(equalToConstant: 150).isActive = true
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 6, dy: 6)
        let wet = NSColor.controlAccentColor

        // The screen, standing in for the wallpaper behind everything.
        let screen = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.setFill()
        screen.fill()

        // The sky, as a plain vertical wash — this is a diagram, not a render,
        // and pretending otherwise would misrepresent it.
        NSGraphicsContext.saveGraphicsState()
        screen.addClip()
        let sky = NSGradient(colors: [
            NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.72, alpha: 1),
            NSColor(calibratedRed: 0.62, green: 0.76, blue: 0.90, alpha: 1),
        ])
        sky?.draw(in: r, angle: -90)

        if wetPane {
            // Beading on the glass: scattered dots over the whole screen.
            NSColor.white.withAlphaComponent(0.16 + 0.34 * pane).setFill()
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) % 10_000) / 10_000
            }
            for _ in 0..<70 {
                let d = 1.2 + rnd() * 2.6
                let x = r.minX + rnd() * r.width, y = r.minY + rnd() * r.height
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        func plate(_ rect: NSRect, radius: CGFloat, on: Bool, label: String) {
            let p = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            p.fill()
            if on {
                wet.withAlphaComponent(0.30 + 0.45 * furniture).setFill()
                p.fill()
                wet.setStroke()
                p.lineWidth = 1.5
                p.stroke()
            } else {
                NSColor.separatorColor.setStroke()
                p.lineWidth = 1
                p.stroke()
            }
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: on ? .semibold : .regular),
                .foregroundColor: on ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let s = NSAttributedString(string: label, attributes: a)
            let sz = s.size()
            s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
        }

        // Menu bar across the top, dock along the bottom, two widgets at the right.
        plate(NSRect(x: r.minX, y: r.minY, width: r.width, height: 14),
              radius: 3, on: wetMenuBar, label: "menu bar")
        plate(NSRect(x: r.midX - 52, y: r.maxY - 26, width: 104, height: 20),
              radius: 8, on: wetDock, label: "dock")
        plate(NSRect(x: r.maxX - 54, y: r.minY + 24, width: 46, height: 34),
              radius: 6, on: wetWidgets, label: "widget")
        plate(NSRect(x: r.maxX - 54, y: r.minY + 64, width: 46, height: 22),
              radius: 6, on: wetWidgets, label: "widget")

        NSColor.separatorColor.setStroke()
        screen.lineWidth = 1
        screen.stroke()
    }
}
