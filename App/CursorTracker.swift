import AppKit

/// Watches the pointer while a mouse button is held and moving, and passes it
/// to `Cursor.shared` when — and only when — the drag STARTED on the bare
/// desktop: the wallpaper, the icons, the widgets. A drag that starts on an app
/// window does nothing, because the scene is not what you are touching there.
///
/// Decided ONCE, at mouse-down, by asking the window server which window is
/// actually under the pointer (`windowNumber(at:)`). This used to re-read the
/// whole window list ten times a second during a drag and test the point
/// against every window's bounds, which was both wasteful and wrong: the
/// list's bounds are where windows WERE, so with "click wallpaper to reveal
/// desktop" sliding every window aside the desktop still looked covered and
/// drags on it did nothing. Hit-testing asks the question the click answers.
///
/// A global monitor sees other apps' mouse events without any permission
/// (only KEY events need Accessibility).
final class CursorTracker {
    private var monitors: [Any] = []
    private var onDesktop = false

    /// Called on the main queue for each desktop drag event, so the host can
    /// lift the frame rate while the scene is being played with.
    var onDrag: (() -> Void)?

    func start() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            self?.onDesktop = Self.desktopUnderPointer()
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in
            self?.handleDrag()
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            self?.onDesktop = false
        }) { monitors.append(m) }
        // A plain HOVER too: the pointer passing over the desktop disturbs
        // what lies and falls there (Cursor.hover). At most thirty times a
        // second, and the window under it is asked at most ten.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            self?.handleHover()
        }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private var lastHover: CFAbsoluteTime = 0
    private var lastHoverCheck: CFAbsoluteTime = 0
    private var hoverOnDesktop = false

    private func handleHover() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastHover > 1.0 / 30 else { return }
        lastHover = now
        if now - lastHoverCheck > 0.1 {
            lastHoverCheck = now
            hoverOnDesktop = Self.desktopUnderPointer()
        }
        guard hoverOnDesktop else { return }
        let m = NSEvent.mouseLocation
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        Cursor.shared.hovered(to: CGPoint(x: m.x, y: primaryH - m.y))
        onDrag?()
    }

    private func handleDrag() {
        guard onDesktop else { return }
        // Global, top-left origin — the window list's coordinate space, which
        // is what Cursor and each surface's frame are in.
        let m = NSEvent.mouseLocation
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        Cursor.shared.dragged(to: CGPoint(x: m.x, y: primaryH - m.y))
        onDrag?()
    }

    /// True when the topmost window under the pointer belongs to the desktop:
    /// below the normal window layer (Finder's icons, the widgets, wallpaper),
    /// or our own wallpaper window, or nothing at all.
    private static func desktopUnderPointer() -> Bool {
        let num = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        guard num > 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(num))
                as? [[String: Any]], let w = info.first else { return true }
        if (w[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier {
            return true
        }
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        return layer < 0
    }
}
