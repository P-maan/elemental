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

    /// Size in points this instance is drawn at. The RENDER size is always
    /// `pixels`; this only decides how big the finished image is shown.
    let displayPoints: NSSize

    static let pixels = ScenePreview.large
    static let points = NSSize(width: ScenePreview.large.width / 2,
                               height: ScenePreview.large.height / 2)
    /// The size the hero is DRAWN at now that it lives in the pane's pinned
    /// header rather than in the scrolling column. Same 800x500 render — same
    /// renderer, same cache key — displayed smaller, because every point of
    /// header height is a point the controls below do not get.
    static let pinnedPoints = NSSize(width: 320, height: 200)

    private let imageView = NSImageView()
    private let placeholder = NSTextField(labelWithString: "")
    private var issued = 0
    private var shown = -1
    private(set) var spec: PreviewSpec?

    init(points: NSSize = HeroPreview.points) {
        self.displayPoints = points
        super.init(frame: NSRect(origin: .zero, size: points))
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
            widthAnchor.constraint(equalToConstant: displayPoints.width),
            heightAnchor.constraint(equalToConstant: displayPoints.height),
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
// There used to be a `FurnitureDiagram` here: a drawn miniature of a screen with
// its menu bar, dock and two notional widgets, lit up according to which of them
// weather was allowed to mark. It has been replaced by `DesktopGridView` in
// DesktopGrid.swift, which draws the user's ACTUAL screen shape with their
// actual widgets on it — and lets them be dragged. A diagram of a generic
// desktop was the right answer while the widget rectangles were unknowable; it
// is the wrong one now that they can be handed in.
