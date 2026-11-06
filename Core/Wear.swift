import Foundation
import CoreGraphics

/// Where the pointer goes, worn in over days — desire paths.
///
/// Asked for 6 Nov 2026: "in nature the places we go most, the leaves and
/// water dry out faster, like it creates paths — so leaves, snow and other
/// things drift apart from the top of the Dock where the mouse goes the most."
///
/// The host samples the pointer once a second (no event monitor, nothing per
/// frame) and counts only when it has MOVED since the last look — a pointer
/// parked over a document for an hour is not foot traffic. A click counts as a
/// few seconds' worth. Each cell's tally fades with a half-life of two days,
/// so a path you stop using grows back over a week.
///
/// Positions are global top-left points, like Cursor. The simulation asks
/// `wear(at:)` and gets 0 (untrodden) .. 1 (a beaten path).
final class Wear: @unchecked Sendable {
    static let shared = Wear()
    private let lock = NSLock()

    /// Cell size, in points.
    static let cell: CGFloat = 20
    /// Seconds of passing in one cell that make a well-worn path (wear 0.63).
    static let worn: Float = 240
    /// Half-life of a path, in seconds.
    static let halfLife: Double = 2 * 86400

    private var tally: [Int64: Float] = [:]
    private var lastDecay = CFAbsoluteTimeGetCurrent()
    private var last: CGPoint?
    private(set) var changed = false

    private static func key(_ gx: Int, _ gy: Int) -> Int64 { Int64(gx) << 32 | Int64(UInt32(bitPattern: Int32(gy))) }

    /// The pointer is at `p` now. Called about once a second.
    func sample(_ p: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        defer { last = p }
        guard let l = last, hypot(p.x - l.x, p.y - l.y) > 2 else { return }
        // Along the way from the last look, not only where it ended: a sweep
        // across the Dock wears every icon it passed over, a little.
        let steps = max(1, min(40, Int(hypot(p.x - l.x, p.y - l.y) / Self.cell)))
        let each = Float(1) / Float(steps)
        for k in 1...steps {
            let t = CGFloat(k) / CGFloat(steps)
            add(CGPoint(x: l.x + (p.x - l.x) * t, y: l.y + (p.y - l.y) * t), each * (k == steps ? 2 : 1))
        }
        decayIfDue()
    }

    /// A click at `p` — where you stop to do something.
    func click(_ p: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        add(p, 4)
    }

    private func add(_ p: CGPoint, _ v: Float) {
        let gx = Int((p.x / Self.cell).rounded(.down)), gy = Int((p.y / Self.cell).rounded(.down))
        tally[Self.key(gx, gy), default: 0] += v
        changed = true
    }

    private func decayIfDue() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastDecay
        guard dt > 600 else { return }
        lastDecay = now
        let k = Float(pow(0.5, dt / Self.halfLife))
        for (key, v) in tally {
            let n = v * k
            tally[key] = n < 0.5 ? nil : n
        }
    }

    /// How worn the ground is at `p`, 0..1: the cell and, at half weight,
    /// its neighbours, so a path has soft shoulders rather than a ruled edge.
    func wear(at p: CGPoint) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard !tally.isEmpty else { return 0 }
        let gx = Int((p.x / Self.cell).rounded(.down)), gy = Int((p.y / Self.cell).rounded(.down))
        var t: Float = 0
        for dy in -1...1 {
            for dx in -1...1 {
                let v = tally[Self.key(gx + dx, gy + dy)] ?? 0
                t += v * (dx == 0 && dy == 0 ? 1 : 0.35)
            }
        }
        return 1 - exp(-t / Self.worn)
    }

    // MARK: memory

    private struct Saved: Codable { var saved: Date; var cells: [Int64: Float] }

    func save(to url: URL) {
        lock.lock()
        guard changed else { lock.unlock(); return }
        let s = Saved(saved: Date(), cells: tally)
        changed = false
        lock.unlock()
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }

    func load(from url: URL) {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        let away = max(0, Date().timeIntervalSince(s.saved))
        let k = Float(pow(0.5, away / Self.halfLife))
        lock.lock()
        tally = s.cells.compactMapValues { v in v * k < 0.5 ? nil : v * k }
        lock.unlock()
    }

    /// Render tool: a worn band across `rect` (global points), as if walked
    /// for days.
    func forcePath(_ rect: CGRect, strength: Float) {
        lock.lock(); defer { lock.unlock() }
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX { add(CGPoint(x: x, y: y), strength * Self.worn); x += Self.cell }
            y += Self.cell
        }
    }
}
