//  AppIcons.swift — the app's own icon, in three designs, chosen in Settings.
//
//  Two halves that never run at the same time:
//
//    ART      composes an icon from the artwork in the three Icon Composer
//             bundles at the project root, and writes Icons/*.icns. Run by
//             hand, `Elemental --make-icons`, and its output is checked in.
//             Nothing about a build or a launch touches it.
//    RUNTIME  loads those .icns out of the app's own Resources for the
//             Settings thumbnails, and applies the chosen one to the bundle.
//
//  ---- Why the artwork is baked rather than compiled by the icon toolchain
//
//  An Icon Composer .icon bundle is normally handed to `actool`, which knows
//  how to apply its glass, shadow, translucency and per-appearance fills. That
//  is not available here: this project builds with the Command Line Tools and
//  no Xcode project, on purpose (see build.sh), and `xcrun actool` on this
//  machine refuses to run at all — "a required plugin failed to load". So the
//  layer stack in each icon.json is composed here instead, honouring the parts
//  that carry the design: which images, at what scale, at what offset, in what
//  order, in the fill each layer names for a dark appearance. What is NOT
//  reproduced is Icon Composer's material — the specular glass and the
//  translucency — because approximating those badly would look worse than a
//  clean flat rendering of the same lockup. 001 is unaffected either way: its
//  artwork is a finished full-bleed PNG with its own glass frame.
//
//  ---- Why the choice is applied with setIcon rather than by swapping a file
//
//  Everything under Contents/ is covered by the code signature. Rewriting
//  Resources/AppIcon.icns at runtime would break the seal, and this project has
//  already been bitten by exactly that: a modified bundle resource is what got
//  the screen saver SIGKILLed at load (build.sh says so at length). A custom
//  Finder icon is stored OUTSIDE Contents — macOS writes it as an `Icon\r` file
//  at the top level of the bundle — so it changes what the icon looks like
//  without touching anything that is signed.

import AppKit

// MARK: - Runtime

enum AppIcons {

    /// The icon for a style, from the app's own Resources. Nil when the build
    /// did not copy the .icns in, which is survivable everywhere it is used.
    static func image(_ style: AppIconStyle) -> NSImage? {
        guard let url = Bundle.main.url(forResource: style.resourceName, withExtension: "icns")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Make the app wear `style`.
    ///
    /// `applicationIconImage` covers what this process draws for itself —
    /// alerts, the About panel, Notification Center. The Finder icon covers
    /// what the bundle looks like sitting in /Applications. Selecting the
    /// default clears the custom icon rather than setting an identical one, so
    /// a bundle that has never been customised stays clean.
    static func apply(_ style: AppIconStyle) {
        guard let img = image(style) else { return }
        NSApp.applicationIconImage = img

        let path = Bundle.main.bundlePath
        if style == .mark {
            // 002 is what the bundle already carries as AppIcon.icns.
            NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
        } else {
            NSWorkspace.shared.setIcon(img, forFile: path, options: [])
        }
    }
}

// MARK: - Picking one

/// The three designs as thumbnails, in the vocabulary the rest of Settings
/// uses: a rounded tile, a caption under it, an accent ring on the one that is
/// selected, and the whole row acting as a radio group. `PreviewChoice` does
/// exactly this for scene thumbnails and cannot be reused directly — it renders
/// its picture from a `PreviewSpec` through the scene renderer, and these are
/// finished images off disk — so this is the same shape with an image view in
/// place of the render.
final class AppIconPicker: NSStackView {

    private var tiles: [(style: AppIconStyle, ring: NSView, caption: NSTextField)] = []
    var onPick: ((AppIconStyle) -> Void)?

    private final class Hit: NSView {
        var action: (() -> Void)?
        override func mouseDown(with event: NSEvent) { action?() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }

    init(points: CGFloat = 72) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .horizontal
        alignment = .top
        spacing = 14

        for style in AppIconStyle.allCases {
            let ring = Hit()
            ring.translatesAutoresizingMaskIntoConstraints = false
            ring.wantsLayer = true
            ring.layer?.cornerRadius = 10
            ring.layer?.borderWidth = 2
            ring.action = { [weak self] in self?.onPick?(style) }

            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.image = AppIcons.image(style)
            // The image view must not swallow the click that selects the tile.
            iv.isEnabled = false
            ring.addSubview(iv)

            let cap = NSTextField(labelWithString: style.title)
            cap.font = .systemFont(ofSize: 10)
            cap.alignment = .center
            cap.translatesAutoresizingMaskIntoConstraints = false

            let col = NSStackView(views: [ring, cap])
            col.orientation = .vertical
            col.alignment = .centerX
            col.spacing = 3
            col.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                ring.widthAnchor.constraint(equalToConstant: points + 8),
                ring.heightAnchor.constraint(equalToConstant: points + 8),
                iv.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: points),
                iv.heightAnchor.constraint(equalToConstant: points),
            ])
            ring.setAccessibilityRole(.radioButton)
            ring.setAccessibilityLabel(style.title)
            ring.toolTip = style.title
            tiles.append((style, ring, cap))
            addArrangedSubview(col)
        }
        select(.mark)
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ style: AppIconStyle) {
        for t in tiles {
            let on = t.style == style
            t.ring.layer?.borderColor = on ? NSColor.controlAccentColor.cgColor
                                           : NSColor.clear.cgColor
            t.caption.textColor = on ? .labelColor : .secondaryLabelColor
            t.caption.font = .systemFont(ofSize: 10, weight: on ? .semibold : .regular)
            t.ring.setAccessibilityValue(on)
        }
    }
}

// MARK: - Art
//
// Everything below runs only under `--make-icons`.

enum AppIconArt {

    /// Canvas the layer positions in icon.json are expressed on.
    static let canvas: CGFloat = 1024

    /// The sky the marks sit on: night at the top, dusk at the bottom. The app
    /// draws skies, so its icon is one — and a dark ground is what the supplied
    /// icon.json files assume, since every layer in 002 and 003 names a white
    /// or near-white fill.
    static let skyTop = NSColor(srgbRed: 0.075, green: 0.098, blue: 0.180, alpha: 1)
    static let skyBottom = NSColor(srgbRed: 0.286, green: 0.365, blue: 0.510, alpha: 1)
    /// The near-white in 002/003's dark fill specialization, display-p3
    /// 0.94009 0.95323 0.96783, taken as sRGB — the difference at this
    /// saturation is under a code point.
    static let glyphWhite = NSColor(srgbRed: 0.94009, green: 0.95323, blue: 0.96783, alpha: 1)

    /// One layer of a composition: an image, how big, and where.
    struct Layer {
        let file: String            // relative to the project root
        let scale: CGFloat          // icon.json "position.scale"
        let dx: CGFloat             // "translation-in-points", x right
        let dy: CGFloat             // y UP, as Icon Composer counts it
        var tint: NSColor? = glyphWhite   // nil keeps the artwork's own colour
        var fullBleed = false       // fills the canvas instead of being placed
    }

    /// The three designs, transcribed from the icon.json files.
    static func layers(_ style: AppIconStyle) -> [Layer] {
        switch style {
        case .mosaic:
            return [Layer(file: "Elemental 001.icon/Assets/light.png",
                          scale: 1, dx: 0, dy: 0, tint: nil, fullBleed: true)]
        case .mark:
            return [Layer(file: "ELemental 002.icon/Assets/El.svg",
                          scale: 15, dx: 3.732584652750006, dy: 3.6888619740000195)]
        case .lockup:
            return [
                Layer(file: "ELemental 003.icon/Assets/∞.svg",
                      scale: 5, dx: -277.395964766175, dy: -324.14668997556504),
                Layer(file: "ELemental 003.icon/Assets/7021.svg",
                      scale: 2, dx: 253.73743125061253, dy: 339.8352380802835),
                Layer(file: "ELemental 003.icon/Assets/Elemental.svg",
                      scale: 2, dx: 1.221655907400077, dy: 213.5281669690637),
                Layer(file: "ELemental 003.icon/Assets/El.svg",
                      scale: 10, dx: 2.986067722200005, dy: -46.86582552599998),
            ]
        }
    }

    /// Compose one icon at `size` pixels square.
    static func render(_ style: AppIconStyle, size: CGFloat, projectRoot: String) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        let k = size / canvas                      // canvas points -> pixels
        let shape = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                                 xRadius: size * 0.2246, yRadius: size * 0.2246)

        if style != .mosaic {
            shape.setClip()
            NSGradient(starting: skyBottom, ending: skyTop)?
                .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: 90)
        }

        for l in layers(style) {
            guard let art = NSImage(contentsOfFile: projectRoot + "/" + l.file) else {
                FileHandle.standardError.write("  missing artwork: \(l.file)\n".data(using: .utf8)!)
                continue
            }
            let box: NSRect
            if l.fullBleed {
                box = NSRect(x: 0, y: 0, width: size, height: size)
            } else {
                let w = art.size.width * l.scale * k
                let h = art.size.height * l.scale * k
                box = NSRect(x: (size - w) / 2 + l.dx * k,
                             y: (size - h) / 2 + l.dy * k, width: w, height: h)
            }
            if let tint = l.tint {
                // The SVGs are filled black. Draw them, then replace the colour
                // through the coverage they laid down — which is the same
                // "fill-specializations" idea the icon.json expresses, with one
                // fill instead of three.
                let layer = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                layer.size = NSSize(width: size, height: size)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: layer)
                NSGraphicsContext.current?.imageInterpolation = .high
                art.draw(in: box)
                tint.set()
                NSRect(x: 0, y: 0, width: size, height: size).fill(using: .sourceAtop)
                NSGraphicsContext.restoreGraphicsState()
                // `NSImageRep.draw(in:)` composites with COPY, which wipes
                // everything already on the canvas — the gradient, and every
                // layer under this one. Three of 003's four layers and the sky
                // behind all of them vanished exactly that way.
                layer.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                           from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
            } else {
                art.draw(in: box)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // 001's artwork carries its own frame and its own transparent corners,
        // so it is masked only to keep a stray pixel out of the corner; the
        // other two are already clipped to the shape they were drawn into.
        return rep
    }

    // MARK: ICNS

    /// The sizes an .icns wants, with the four-character type for each.
    /// PNG payloads throughout, which macOS has read since 10.7 and which is
    /// what `iconutil` itself writes — this container is assembled here so the
    /// step does not need Xcode's tools any more than the build does.
    static let entries: [(type: String, px: CGFloat)] = [
        ("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64),
        ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512),
        ("ic09", 512), ("ic10", 1024),
    ]

    static func icns(_ style: AppIconStyle, projectRoot: String) -> Data {
        var body = Data()
        var cache: [CGFloat: Data] = [:]
        for e in entries {
            let png: Data
            if let c = cache[e.px] { png = c } else {
                png = render(style, size: e.px, projectRoot: projectRoot)
                    .representation(using: .png, properties: [:]) ?? Data()
                cache[e.px] = png
            }
            guard !png.isEmpty else { continue }
            body.append(contentsOf: Array(e.type.utf8))
            var len = UInt32(png.count + 8).bigEndian
            withUnsafeBytes(of: &len) { body.append(contentsOf: $0) }
            body.append(png)
        }
        var out = Data("icns".utf8)
        var total = UInt32(body.count + 8).bigEndian
        withUnsafeBytes(of: &total) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// `Elemental --make-icons [projectRoot]`. Writes Icons/*.icns.
    static func makeAll(projectRoot: String) -> Bool {
        let dir = projectRoot + "/Icons"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var ok = true
        for style in AppIconStyle.allCases {
            let data = icns(style, projectRoot: projectRoot)
            let path = dir + "/" + style.resourceName + ".icns"
            do {
                try data.write(to: URL(fileURLWithPath: path))
                print("  wrote \(path)  \(data.count) bytes")
            } catch {
                print("  FAILED \(path): \(error)"); ok = false
            }
            // A PNG of the 1024 alongside, purely so the result can be looked
            // at without unpacking an icns.
            if let png = render(style, size: 1024, projectRoot: projectRoot)
                .representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/" + style.resourceName + "-1024.png"))
            }
        }
        return ok
    }
}
