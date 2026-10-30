import AppKit

/// Watches the pointer while a mouse button is held and moving, and passes it
/// to `Cursor.shared` when — and only when — it is over the bare desktop: the
/// wallpaper, the icons, the widgets. Dragging across an app window does
/// nothing, because the scene is not what you are touching there.
///
/// A global monitor sees other apps' mouse events without any permission
/// (only KEY events need Accessibility). Whether the point is on the desktop
/// comes from the window list: any ordinary window (layer 0 and up) under the
/// point means an app is in the way. The Dock's full-screen overlay and the
/// window server's own layers are not "in the way". The check is cached for a
/// tenth of a second so a fast drag costs a handful of lookups, not hundreds.
final class CursorTracker {
    private var monitor: Any?
    private var lastCheck: CFAbsoluteTime = 0
    private var lastAnswer = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            self?.handle()
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handle() {
        // Global, top-left origin — the window list's coordinate space.
        guard let p = CGEvent(source: nil)?.location else { return }
        guard overDesktop(p) else { return }
        Cursor.shared.dragged(to: p)
    }

    private func overDesktop(_ p: CGPoint) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastCheck < 0.1 { return lastAnswer }
        lastCheck = now
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            lastAnswer = false
            return false
        }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < 20,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let owner = w[kCGWindowOwnerName as String] as? String,
                  owner != "Dock", owner != "Window Server",
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0.05
            else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.contains(p) { lastAnswer = false; return false }
        }
        lastAnswer = true
        return true
    }
}
