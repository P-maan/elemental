//  LockStill.swift — the lock screen, as far as macOS allows.
//
//  A third-party app cannot draw on the lock screen. loginwindow puts an opaque
//  secure surface above every window level, including the desktop level our
//  wallpaper lives at; a window there keeps rendering but nobody can see it.
//  That is deliberate on Apple's part — an app that could draw over the lock
//  screen could imitate it and harvest passwords. Apple DTS is explicit about
//  it, and nothing in macOS 27 has moved: WallpaperExtensionKit exists but is
//  private, built against an internal SDK, and registers no public extension
//  point.
//
//  So there are exactly two routes to the lock screen, and Elemental uses both:
//
//    still   the lock screen derives its background from the desktop picture,
//            so writing a current frame there and setting it as the desktop
//            image puts the real scene behind the lock UI. That is this file.
//
//    live    the screen saver is the one sanctioned animated surface at lock.
//            Set it to activate on lock and the lock screen genuinely animates.
//            That is Elemental.saver.

import AppKit
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class LockStillExporter {

    private let renderer: ElementalRenderer?
    private var timer: Timer?
    private var texture: MTLTexture?
    private var size = CGSize(width: 1512, height: 982)

    /// Everything after the Metal render happens here, never on the caller.
    ///
    /// The fourth bug this exporter has caused, and the worst-looking one: the
    /// timer fires on the main runloop, which is also where CAMetalDisplayLink
    /// drives the wallpaper. Encoding a full-screen PNG, writing it, handing it
    /// to WallpaperAgent and mirroring it into the store took long enough that a
    /// sample of the running app caught 548 frames inside the export against 33
    /// actually animating. The wallpaper stopped dead for the duration and then
    /// integrated the accumulated time in one step — a freeze and a jump, once a
    /// minute. None of that work needs the main thread.
    ///
    /// Serial, so two exports can never interleave in the wallpaper store, and
    /// so `currentURL` needs no lock: it is only ever touched from this queue.
    private let exportQueue = DispatchQueue(label: "com.elemental.lockstill.export",
                                            qos: .utility)

    /// Main thread only. The texture is reused between exports, so a second
    /// export must not start rendering into it while the first is still reading
    /// it out on the queue. At one export a minute this should never trip; if it
    /// does, skipping is right — the next frame is a minute away.
    private var exporting = false

    /// A filename macOS has never seen before, every single time.
    ///
    /// This is the third attempt and the first correct one, so the history is
    /// worth recording:
    ///
    ///   1. One fixed filename. macOS caches the desktop picture BY URL, so it
    ///      kept serving the version cached on first use — for days.
    ///   2. Two alternating filenames. Fine for one cycle, then just as broken:
    ///      both names are reused every cycle, so the cache still held an old
    ///      entry for whichever came up. The symptom was a lock screen showing
    ///      yesterday's sky, occasionally snapping to some other past render as
    ///      the cache turned over.
    ///
    /// A unique name per write is the only thing that reliably defeats it —
    /// there is no cache entry to hit. Old files are swept afterwards on a
    /// delay, because deleting the file macOS has just taken a reference to is
    /// its own race, which was attempt two's other bug.
    private var currentURL: URL?

    private func makeFileURL() -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        return Config.directory.appendingPathComponent("scene-\(stamp).png")
    }

    /// Current conditions. Held rather than passed on every call because the
    /// timer path has no other way to reach them.
    private var weatherProvider: () -> WeatherState = { WeatherState() }

    init(device: MTLDevice) {
        renderer = ElementalRenderer(device: device, colorFormat: .rgba8Unorm)
        // No transitions here. This renderer draws one frame a minute, so its
        // frame-to-frame dt is a tenth of a second an hour: an eased sky would
        // creep toward each reading at a thousandth of real speed and the lock
        // screen would be showing yesterday by tea time. A still is a picture
        // of the conditions as reported, and the desktop is where they move.
        renderer?.easeTransitions = false
    }

    func start(configProvider: @escaping () -> Config,
               astroProvider: @escaping () -> AstroState,
               weatherProvider: @escaping () -> WeatherState)
    {
        self.weatherProvider = weatherProvider
        stop()
        // Once a minute. The lock screen is a still, so the only thing that
        // makes it feel alive is being recent — and one offscreen frame is
        // cheap enough that there is no reason to be stingy.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.export(config: configProvider(), astro: astroProvider())
        }
        export(config: configProvider(), astro: astroProvider())
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Render and install a fresh still right now — called on the way into a
    /// lock so the lock screen shows the sky as of that moment.
    func exportNow(config: Config, astro: AstroState) { export(config: config, astro: astro) }

    private func export(config: Config, astro: AstroState) {
        guard config.syncLockScreen, let renderer else { return }
        guard !exporting else { return }

        if let main = NSScreen.main {
            let s = main.frame.size
            size = CGSize(width: s.width * main.backingScaleFactor,
                          height: s.height * main.backingScaleFactor)
        }
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return }

        if texture == nil || texture!.width != w || texture!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            texture = renderer.device.makeTexture(descriptor: d)
        }
        guard let tex = texture else { return }

        // Settings FIRST, then size. The renderer builds the mosaic grid inside
        // resize() from whatever row count its state happens to hold, so doing
        // this the other way round — which is what it used to do — built the
        // grid from the SceneState default and then assigned the real settings
        // too late to matter. resize() was only ever called again when the
        // display changed size, so the lock screen's grid stayed at the default
        // for the life of the process: with "Mimic Home Screen" on it drew the
        // desktop's colour, shape, finish and relief over a grid that was not
        // the desktop's at all, which is exactly what "it does not mimic" looks
        // like. Toggling the setting did not help, because nothing in that path
        // resizes either.
        var s = renderer.state
        config.apply(to: &s)
        s.astro = astro
        // Weather has to be set explicitly: config.apply carries appearance
        // only, so without this the still renders the default WeatherState —
        // a clear sky — while the desktop shows the real thing. Sun and moon
        // still looked right, which is what made it hard to spot.
        s.weather = weatherProvider()
        renderer.state = s
        // Unconditional, every export. The renderer decides for itself whether
        // anything needs rebuilding — it compares the size AND the row count —
        // so this is free when nothing changed and correct when it did.
        renderer.resize(width: w, height: h)

        // The clock and the login field, as collision geometry.
        //
        // This still ends up BEHIND the real lock screen UI, so water has to
        // treat that UI as solid the same way the desktop treats the dock and
        // the saver treats these exact rectangles (Furniture.lockScreen, also
        // used by ElementalSaver). Without it the exporter was the one renderer
        // in the project with no furniture at all: rain fell straight through
        // the clock and the login box and landed on the bottom of the frame,
        // which is the one place nobody can see, so the still had none of the
        // splash the live saver has.
        //
        // Same pixel dimensions the frame is rendered at, so the rectangles line
        // up with where loginwindow actually draws. The login box is included:
        // this image is the lock screen's background, and the lock screen has a
        // password field on it — the saver only omits it for the little preview
        // thumbnail in System Settings, which has no login UI over it.
        renderer.surfaces = Furniture.lockScreen(width: Float(w), height: Float(h),
                                                 includeLoginBox: true)
        renderer.render(to: tex, waitForCompletion: true)

        // Everything past here is bytes and files, not Metal, and none of it is
        // fast. Hand it to the queue and let the display link have its thread
        // back. NSScreen.screens is read here because it is AppKit state and
        // belongs on the main thread; the screens themselves are only used as
        // opaque handles for setDesktopImageURL.
        let screens = NSScreen.screens
        exporting = true
        exportQueue.async { [weak self] in
            guard let self else { return }
            self.install(from: tex, width: w, height: h, screens: screens)
            DispatchQueue.main.async { self.exporting = false }
        }
    }

    /// Encode, write, install, mirror, sweep — all on `exportQueue`.
    ///
    /// The render has already completed (`waitForCompletion: true`) and the
    /// `exporting` flag keeps anyone else off the texture, so reading it out
    /// here is safe.
    private func install(from tex: MTLTexture, width w: Int, height h: Int,
                         screens: [NSScreen])
    {
        guard let img = makeImage(from: tex, width: w, height: h) else { return }
        try? FileManager.default.createDirectory(at: Config.directory,
                                                 withIntermediateDirectories: true)
        let fileURL = makeFileURL()
        guard let dest = CGImageDestinationCreateWithURL(
                fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return }

        for screen in screens {
            try? NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: [:])
        }
        currentURL = fileURL
        // Also refresh any path the wallpaper store still references.
        //
        // NSWorkspace.setDesktopImageURL only writes the per-display scope. The
        // store also has a SystemDefault scope, which loginwindow falls back to
        // because at the lock screen there is no display or space context — and
        // nothing in the public API updates it. WallpaperAgent owns that file
        // and reverts edits to it, so we cannot repoint it either.
        //
        // What we can do is make the path it already points at hold a current
        // image. That is the difference between a lock screen showing a picture
        // from days ago and one showing now.
        mirrorToReferencedPaths(image: img)
        sweepOldStills(keeping: fileURL)
        // Both files are deliberately left on disk.
        //
        // Deleting the one we are no longer pointing at seems tidy and is a
        // race: setDesktopImageURL is asynchronous, and the wallpaper store
        // holds several scopes that update at different times. Removing the
        // other file left macOS pointing at a path that no longer existed, and
        // the lock screen simply had nothing to draw. Two PNGs is a rounding
        // error; a broken lock screen is not.
    }

    /// Paths inside our own directory that the wallpaper store still names.
    /// Re-read each time rather than cached, because the agent rewrites the
    /// store on its own schedule.
    private func referencedPaths() -> [URL] {
        let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: store),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return [] }

        var found: Set<String> = []
        func walk(_ any: Any) {
            if let dict = any as? [String: Any] {
                if let cfg = dict["Configuration"] as? Data, !cfg.isEmpty,
                   let inner = try? PropertyListSerialization.propertyList(from: cfg, format: nil)
                       as? [String: Any],
                   let url = (inner["url"] as? [String: Any])?["relative"] as? String,
                   let decoded = URL(string: url)?.path,
                   decoded.hasPrefix(Config.directory.path) {
                    found.insert(decoded)
                }
                dict.values.forEach(walk)
            } else if let arr = any as? [Any] {
                arr.forEach(walk)
            }
        }
        walk(plist)
        return found.map { URL(fileURLWithPath: $0) }
    }

    /// Write the same frame to every path the store still names, so no scope is
    /// left pointing at a stale or missing file.
    private func mirrorToReferencedPaths(image: CGImage) {
        for url in referencedPaths() where url != currentURL {
            guard let dest = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// Remove stills we are no longer pointing at, but only once they are old
    /// enough that macOS cannot still be reading them. Deleting eagerly is what
    /// left the wallpaper pointing at a missing file last time.
    private func sweepOldStills(keeping current: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Config.directory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-300)      // five minutes' grace
        let referenced = Set(referencedPaths().map(\.path))
        for f in files where f.lastPathComponent.hasPrefix("scene-")
                          && f != current && !referenced.contains(f.path) {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod > cutoff { continue }
            try? fm.removeItem(at: f)
        }
        // The old fixed names are deliberately NOT deleted: the store may still
        // reference one, and removing it is what left the lock screen pointing
        // at nothing. mirrorToReferencedPaths keeps them current instead.
    }

    private func makeImage(from tex: MTLTexture, width: Int, height: Int) -> CGImage? {
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels.withUnsafeMutableBytes { p in
            tex.getBytes(p.baseAddress!, bytesPerRow: rowBytes,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
