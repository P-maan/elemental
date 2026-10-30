import Foundation
import CoreGraphics

/// The pointer, while it is DRAGGING ON THE DESKTOP — so the scene can play
/// with it. Asked for 30 Oct 2026: "when the cursor moves while dragging on the
/// screen, like the desktop, the elements react in their own funny way".
///
/// The host (CursorTracker, in the app) reports drag positions in GLOBAL
/// coordinates — points, origin at the top left of the primary display, which
/// is what the window list uses. Each surface asks for the state in its own
/// pixels. `drag` is how alive the gesture is: 1 while moving, fading over a
/// third of a second once the pointer stops or lifts, so the scene settles
/// back rather than snapping.
final class Cursor: @unchecked Sendable {
    static let shared = Cursor()
    private let lock = NSLock()
    private var pos = CGPoint(x: -1e5, y: -1e5)
    private var vel = CGVector(dx: 0, dy: 0)
    private var lastMove: CFAbsoluteTime = -100

    struct State {
        /// Position and velocity in this surface's pixels (velocity per second).
        var x: Float, y: Float, vx: Float, vy: Float
        /// 0..1, how alive the drag is.
        var drag: Float
    }

    func dragged(to p: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastMove
        if dt > 0.001 && dt < 0.25 {
            // Smoothed, so a jittery trackpad gives a steady direction.
            let k = 0.35
            vel.dx += k * ((p.x - pos.x) / dt - vel.dx)
            vel.dy += k * ((p.y - pos.y) / dt - vel.dy)
        } else {
            vel = .zero
        }
        pos = p
        lastMove = now
    }

    /// `frame` is the surface's screen in global top-left points.
    func state(in frame: CGRect, scale: CGFloat) -> State {
        lock.lock(); defer { lock.unlock() }
        let age = CFAbsoluteTimeGetCurrent() - lastMove
        guard age < 2, frame.insetBy(dx: -80, dy: -80).contains(pos) else {
            return State(x: -1e5, y: -1e5, vx: 0, vy: 0, drag: 0)
        }
        return State(x: Float((pos.x - frame.minX) * scale),
                     y: Float((pos.y - frame.minY) * scale),
                     vx: Float(vel.dx * scale), vy: Float(vel.dy * scale),
                     drag: Float(exp(-age / 0.33)))
    }
}
