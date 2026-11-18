import CoreMotion
import Foundation

/// Where his head is pointing, from AirPods / Beats with head tracking
/// (17 Nov 2026, his ask: "get motion data from connected headphones ... and
/// change the glimmer direction to that"). CMHeadphoneMotionManager hands over
/// the headphones' attitude; this keeps it RELATIVE to a slowly following centre,
/// so turning to look at something swings the light and the shimmer, and sitting
/// turned for a while lets it settle back - it never needs calibrating.
/// Nothing in the sky moves with it: the sun, moon, stars and weather stay true.
final class HeadTracker: @unchecked Sendable {
    static let shared = HeadTracker()
    private let mgr = CMHeadphoneMotionManager()
    private let q = OperationQueue()
    private let lock = NSLock()
    private var yaw: Double = 0, pitch: Double = 0, roll: Double = 0
    private var baseYaw: Double?, basePitch: Double = 0
    private var lastAt: CFAbsoluteTime = 0
    private var lastSample: CFAbsoluteTime = 0
    private(set) var started = false
    private(set) var status = "off"
    /// Strength from the setting, 0..2 (1 = as designed).
    var amount: Float = 1

    func start() {
        guard !started else { return }
        guard mgr.isDeviceMotionAvailable else { status = "not available on this Mac"; return }
        started = true
        status = "waiting for headphones"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        mgr.startDeviceMotionUpdates(to: q) { [weak self] m, err in
            guard let self else { return }
            if let err { self.lock.lock(); self.status = "error: \(err.localizedDescription)"; self.lock.unlock(); return }
            guard let a = m?.attitude else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            let now = CFAbsoluteTimeGetCurrent()
            let dt = min(0.2, max(0.001, now - (self.lastSample == 0 ? now : self.lastSample)))
            self.lastSample = now
            // unwrap yaw against the following centre
            if self.baseYaw == nil { self.baseYaw = a.yaw; self.basePitch = a.pitch }
            var dy = a.yaw - self.baseYaw!
            while dy > .pi { dy -= 2 * .pi }
            while dy < -.pi { dy += 2 * .pi }
            // the centre follows over ~25 s, so a held turn settles back to neutral
            let follow = 1 - exp(-dt / 25)
            self.baseYaw! += dy * follow
            self.basePitch += (a.pitch - self.basePitch) * follow
            self.yaw = dy
            self.pitch = a.pitch - self.basePitch
            self.roll = a.roll
            self.lastAt = now
            self.status = "tracking"
        }
    }

    func stop() {
        guard started else { return }
        mgr.stopDeviceMotionUpdates()
        started = false
        status = "off"
    }

    /// Yaw/pitch/roll in radians relative to the resting centre, and how present
    /// the headphones are (fades to 0 within a second of the data stopping).
    // 18 Nov, his: "the head tracking is getting stuck - make it really smooth". The headphones
    // report ~25 times a second and the wall draws at its own rate, so each frame read a value
    // that jumped in steps. Every read now eases toward the latest pose with a critically damped
    // spring (~90 ms), so the picture glides between reports whatever the frame rate.
    private var sYaw: Double = 0, sPitch: Double = 0, sRoll: Double = 0
    private var vYaw: Double = 0, vPitch: Double = 0, vRoll: Double = 0
    private var sOn: Double = 0, lastRead: CFAbsoluteTime = 0
    /// How fast the head is turning (rad/s), for the frame rate.
    private(set) var speed: Double = 0

    func state() -> (yaw: Float, pitch: Float, roll: Float, on: Float) {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(0.1, max(0.001, now - (lastRead == 0 ? now : lastRead)))
        lastRead = now
        let age = now - lastAt
        let onTarget = lastAt == 0 ? 0 : max(0, min(1, 1.5 - age))
        // Two gentle low-pass stages in a row (unconditionally stable at any frame rate, no
        // overshoot): together they glide like a damped spring, settling in ~120 ms.
        let k = 1 - exp(-dt / 0.045)
        func ease(_ x: inout Double, _ m: inout Double, _ target: Double) {
            m += (target - m) * k
            x += (m - x) * k
        }
        let py = sYaw, pp = sPitch
        ease(&sYaw, &vYaw, yaw); ease(&sPitch, &vPitch, pitch); ease(&sRoll, &vRoll, roll)
        sOn += (onTarget - sOn) * (1 - exp(-dt / 0.25))
        speed = (abs(sYaw - py) + abs(sPitch - pp)) / dt
        return (Float(sYaw), Float(sPitch), Float(sRoll), Float(sOn))
    }
    var isMoving: Bool { lock.lock(); defer { lock.unlock() }; return speed > 0.15 && sOn > 0.2 }

    var report: [String: Any] {
        let s = state()
        func r(_ v: Float) -> Double { (Double(v) * 1000).rounded() / 1000 }
        lock.lock(); let st = status; lock.unlock()
        return ["status": st, "yaw": r(s.yaw), "pitch": r(s.pitch), "roll": r(s.roll), "on": r(s.on)]
    }
}
