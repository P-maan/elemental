//  DesktopSuggestions.swift — look at the screen, then offer, never assert.
//
//  The placement overlay opens over the user's real desktop, so the picture the
//  detector wants is right there. This takes it — every time the overlay opens,
//  not once — runs `FurnitureDetector` over it, and hands the answer to
//  `PlacementModel.setSuggestions`.
//
//  ---- Why the answer is a suggestion and not a placement
//
//  Measured on a real 4112x2658 desktop with seven widgets: four of the six
//  rectangles it produced sat on real widgets, two of them covering a stacked
//  PAIR as one box; two were wallpaper; two real widgets were missed entirely;
//  and the dock's right edge came up 23% short. Written straight into the config
//  that is worse than nothing, because the user then has to work out which of
//  the rectangles they are looking at are wrong before they can fix them. Held
//  apart as a dashed layer they can take or leave, the same output is genuinely
//  useful: four rectangles they did not have to draw.
//
//  So nothing here writes a placement. It fills the suggestion layer, and the
//  model drops anything that lands on work the user has already done.
//
//  ---- Screen Recording
//
//  A screen capture needs the Screen Recording permission, and Elemental has no
//  other reason to hold it. That is a real cost to the user, so:
//
//    * The permission is never demanded. `CGPreflightScreenCaptureAccess` is a
//      question, not a prompt — it does not put a dialog up — so the overlay can
//      ask it, find the answer is no, and open perfectly usable with one line
//      saying why nothing was suggested.
//    * The prompt only ever comes from a button the user pressed.
//    * Manual placement never depends on any of this. Detection is a shortcut
//      round drawing rectangles; drawing rectangles is the feature.
//
//  ---- Threads
//
//  The capture and the reference render are main-thread work (the second is
//  Metal, and building a device on a background queue while the wallpaper is
//  drawing is not something to do casually). Detection is tens of milliseconds
//  of pixel work and goes to a background queue, exactly as it does when a
//  screenshot is dropped on the Elements pane. Nothing here blocks the overlay
//  from appearing: it is put up first and the suggestions arrive into it.

import AppKit
import CoreGraphics
import ScreenCaptureKit

// MARK: - The permission

enum ScreenRecording {

    /// Whether we can capture. This ASKS THE SYSTEM WHAT IT ALREADY DECIDED and
    /// does not prompt, which is what makes it safe to call on every open.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Put the system's prompt up, and open the settings pane behind it for the
    /// case where the answer was already no and macOS will therefore say nothing.
    ///
    /// Only ever called from a button. The grant does not apply to the running
    /// process — macOS requires a relaunch — so the caller should say so rather
    /// than leaving the user pressing Refresh at an overlay that never changes.
    static func request() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Capture and detect

enum DesktopSuggestions {

    /// What one look at the screen produced.
    struct Result {
        var widgets: [CGRect] = []
        var dock: CGRect?
        /// One line for the overlay to show. Always set, including on success —
        /// a suggestion layer nobody explained is a screen full of rectangles
        /// the user did not draw.
        var note: String
        /// The detector's trace, for the harness and for a future log view.
        var log: [String] = []
    }

    /// Capture `screen`, detect, and call back on the main thread.
    ///
    /// Call from the main thread. Returns immediately; the callback lands once
    /// the capture and the detection have both been round.
    static func run(screen: NSScreen, config: Config,
                    completion: @escaping (Result) -> Void) {
        guard ScreenRecording.isGranted else {
            completion(Result(note:
                "Screen Recording is off, so there is nothing to suggest — place everything by "
              + "hand below, or turn it on and reopen this to have Elemental look for itself."))
            return
        }
        capture(screen) { shot in
            guard let shot else {
                completion(Result(note:
                    "The screen could not be captured just now, so nothing is suggested. "
                  + "Everything here can still be placed by hand. If Screen Recording was only "
                  + "just switched on, Elemental has to be relaunched before it takes effect."))
                return
            }
            detect(shot, config: config, completion: completion)
        }
    }

    /// The reference render and the detector. Main thread in, main thread out,
    /// with the expensive middle on a background queue.
    private static func detect(_ shot: CGImage, config: Config,
                               completion: @escaping (Result) -> Void) {
        // The reference frame: our own render of the same scene at the capture's
        // dimensions. Metal work, so it happens here on the main thread, and the
        // comparison itself — which is all the time — goes to a background
        // queue. Same split as the Elements pane's screenshot path.
        let pixels = CGSize(width: shot.width, height: shot.height)
        let reference = DesktopReference.render(pixels: pixels, config: config)
        let grid = SceneSimulation.gridGeometry(pixelWidth: Float(shot.width),
                                                pixelHeight: Float(shot.height),
                                                gridRows: config.gridRows)
        let started = CFAbsoluteTimeGetCurrent()

        DispatchQueue.global(qos: .userInitiated).async {
            let d = FurnitureDetector.detect(shot, reference: reference,
                                             cols: grid.cols, rows: grid.rows)
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            DispatchQueue.main.async {
                var r = Result(widgets: d.widgets, dock: d.dock, note: "", log: d.log)
                if d.isEmpty {
                    r.note = String(format:
                        "Nothing on screen looked like a widget (%.0f ms). Drag a rectangle over "
                      + "each one — that is the reliable way round.", ms)
                } else {
                    r.note = d.summary + String(format: " (%.0f ms) ", ms)
                        + "Dashed rectangles are guesses: click one to keep it, ⌥-click to "
                        + "dismiss it. Nothing you have already placed was touched."
                }
                completion(r)
            }
        }
    }

    /// One frame of the whole display, including the dock and the desktop
    /// widgets — which are windows, and are therefore the reason this needs the
    /// permission at all.
    ///
    /// ScreenCaptureKit, because the one-line `CGWindowListCreateImage` this
    /// wanted to be is not merely deprecated on this SDK but unavailable. Two
    /// asynchronous hops, then, and the callback comes back on the main thread
    /// so the caller never has to think about which queue it is on.
    ///
    /// Elemental's OWN windows are excluded from the filter. Without that the
    /// overlay's dim wash and its HUD would be in the picture the detector is
    /// asked to find rectangles in, which is a guaranteed way to detect a
    /// rectangle that is not there.
    ///
    /// Whatever ELSE is in front of the desktop does land in the shot, so a
    /// screen full of windows produces poor suggestions. That is the same
    /// limitation the screenshot path has always had, and it is why the caller
    /// hides its own settings window for the moment of the capture.
    private static func capture(_ screen: NSScreen,
                                completion: @escaping (CGImage?) -> Void) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard #available(macOS 14.0, *),
              let number = screen.deviceDescription[key] as? NSNumber else {
            completion(nil)
            return
        }
        let wanted = CGDirectDisplayID(number.uint32Value)
        let scale = screen.backingScaleFactor
        let mine = Bundle.main.bundleIdentifier

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
            content, _ in
            guard let content,
                  let display = content.displays.first(where: { $0.displayID == wanted })
                             ?? content.displays.first else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let ours = content.applications.filter { $0.bundleIdentifier == mine }
            let filter = SCContentFilter(display: display, excludingApplications: ours,
                                         exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            // Backing pixels, not points: the detector works in fractions, but
            // it wants every pixel it can get to find a grout line with.
            cfg.width = Int(CGFloat(display.width) * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
            cfg.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                image, _ in
                let ok = (image?.width ?? 0) > 32 && (image?.height ?? 0) > 32
                DispatchQueue.main.async { completion(ok ? image : nil) }
            }
        }
    }
}
