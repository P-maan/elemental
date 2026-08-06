//  PreviewViews.swift — the settings controls that are pictures.
//
//  Three pieces, all thin wrappers over `ScenePreview`:
//
//    PreviewTile     a thumbnail that renders itself from a PreviewSpec
//    PreviewChoice   a tile you can click, with a caption and a selected state
//    PreviewStrip    a row of choices — low / medium / high, or four densities
//
//  The rule they all follow: never block, never render on the main thread, and
//  never render a picture that has already been superseded. See the header of
//  PreviewRenderer.swift for why that matters here specifically.

import AppKit

// MARK: - A thumbnail

class PreviewTile: NSView {

    private let imageView = NSImageView()
    private(set) var spec: PreviewSpec?

    /// Request ordering. Results can arrive out of order — a cache hit returns
    /// synchronously while an older render is still in flight — so a frame is
    /// shown only if it is newer than the one on screen.
    private var issued = 0
    private var shown = -1

    let points: NSSize

    init(points: NSSize, corner: CGFloat = 5) {
        self.points = points
        super.init(frame: NSRect(origin: .zero, size: points))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = corner
        layer?.masksToBounds = true
        // Visible before the first render lands, so an empty tile reads as
        // "loading" rather than as a rendering bug.
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        imageView.imageScaling = .scaleAxesIndependently
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: points.width),
            heightAnchor.constraint(equalToConstant: points.height),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Draw this spec. Cheap to call repeatedly with the same value, and cheap
    /// to call sixty times a second with different ones.
    func show(_ s: PreviewSpec) {
        guard s != spec || imageView.image == nil else { return }
        spec = s
        issued += 1
        let mine = issued
        ScenePreview.shared.request(s, slot: ObjectIdentifier(self)) { [weak self] img in
            guard let self, mine >= self.shown else { return }
            self.shown = mine
            self.imageView.image = img
        }
    }

    /// Render `s` on THIS thread and show it, whatever is already on screen.
    ///
    /// For the offscreen harnesses only, and it exists because of a bug the
    /// harness caught: `show` hands the work to a background queue that answers
    /// on the main queue, so with no runloop the picture never arrives — and
    /// then `show`'s "same spec, already have an image" guard keeps the STALE
    /// one, which is a control that appears to step through densities while
    /// drawing one density. Never call this from the app.
    func showBlocking(_ s: PreviewSpec) {
        spec = s
        shown = issued
        if let img = ScenePreview.shared.cached(s) ?? ScenePreview.shared.renderBlocking(s) {
            imageView.image = img
        }
    }
}

// MARK: - A thumbnail you choose

/// A tile with a caption under it that acts as a radio button. The caption stays
/// because a picture alone is not accessible and not searchable — but the
/// picture is what you actually look at.
final class PreviewChoice: NSView {

    let tile: PreviewTile
    private let caption = NSTextField(labelWithString: "")
    private let frameLayer = NSView()

    var onSelect: (() -> Void)?

    var isSelected = false {
        didSet { guard isSelected != oldValue else { return }; restyle() }
    }

    init(points: NSSize, caption text: String) {
        tile = PreviewTile(points: points)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // A ring drawn just outside the thumbnail, so selection never crops the
        // picture being compared.
        frameLayer.translatesAutoresizingMaskIntoConstraints = false
        frameLayer.wantsLayer = true
        frameLayer.layer?.cornerRadius = 8
        frameLayer.layer?.borderWidth = 2
        frameLayer.addSubview(tile)

        caption.stringValue = text
        caption.font = .systemFont(ofSize: 10)
        caption.alignment = .center
        caption.textColor = .secondaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        addSubview(frameLayer)
        addSubview(caption)
        NSLayoutConstraint.activate([
            frameLayer.topAnchor.constraint(equalTo: topAnchor),
            frameLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
            frameLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
            tile.topAnchor.constraint(equalTo: frameLayer.topAnchor, constant: 3),
            tile.leadingAnchor.constraint(equalTo: frameLayer.leadingAnchor, constant: 3),
            tile.trailingAnchor.constraint(equalTo: frameLayer.trailingAnchor, constant: -3),
            tile.bottomAnchor.constraint(equalTo: frameLayer.bottomAnchor, constant: -3),
            caption.topAnchor.constraint(equalTo: frameLayer.bottomAnchor, constant: 3),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(text)
        toolTip = text
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: PreviewSpec) { tile.show(s) }

    private func restyle() {
        frameLayer.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        caption.textColor = isSelected ? .labelColor : .secondaryLabelColor
        caption.font = .systemFont(ofSize: 10, weight: isSelected ? .semibold : .regular)
        setAccessibilityValue(isSelected)
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - A row of choices

/// Low / medium / high for one slider, or a set of grid densities. Clicking a
/// tile jumps the control to that value, which is the fastest way to explore a
/// range you cannot name.
final class PreviewStrip: NSStackView {

    private(set) var choices: [PreviewChoice] = []
    private let values: [Double]
    /// Called with the value of the tile that was clicked.
    var onPick: ((Double) -> Void)?

    init(points: NSSize, entries: [(value: Double, caption: String)], spacing: CGFloat = 6) {
        values = entries.map(\.value)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .horizontal
        alignment = .top
        self.spacing = spacing
        for (i, e) in entries.enumerated() {
            let c = PreviewChoice(points: points, caption: e.caption)
            c.onSelect = { [weak self] in self?.onPick?(self?.values[i] ?? 0) }
            choices.append(c)
            addArrangedSubview(c)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Draw each tile with `spec` modified to that tile's value.
    func show(_ base: PreviewSpec, applying: (inout PreviewSpec, Double) -> Void) {
        for (i, c) in choices.enumerated() {
            var s = base
            applying(&s, values[i])
            c.show(s)
        }
    }

    /// Ring whichever tile the control is currently sitting on, if any.
    func mark(current: Double, tolerance: Double = 0.02) {
        for (i, c) in choices.enumerated() {
            c.isSelected = abs(values[i] - current) <= tolerance
        }
    }
}
