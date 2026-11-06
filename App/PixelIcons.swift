import SwiftUI

/// dormstand's icons, in the settings. Asked for 6 Nov 2026: "for icons use
/// the icons like in the dorm and room stand".
///
/// Each is an 8x8 sprite, as dormstand's SPR8: `#` a white pixel, `a` a pixel
/// in the accent, `+` a dim one. Every pixel is drawn as a block of the wall —
/// a drop shadow under it, its top edge lit where nothing sits above, the
/// right and bottom edges shaded — the way `sprPaint` raises them on the Pi.
enum PixelIcons {
    static let rows: [String: [String]] = [
        "gearshape.fill": ["...##...", ".#.##.#.", "..####..", "###..###", "###..###", "..####..", ".#.##.#.", "...##..."],
        "leaf.fill": ["......##", "....####", "..#####.", ".####a#.", ".###a##.", ".##a##..", "..a##...", ".a......"],
        "menubar.dock.rectangle": ["########", "#++++++#", "#++++++#", "#++++++#", "#++++++#", "#.aaaa.#", "########", "........"],
        "cube.fill": ["###.###.", "###.###.", "###.###.", "........", "###.aaa.", "###.aaa.", "###.aaa.", "........"],
        "lock.fill": ["..####..", ".#....#.", ".#....#.", "########", "###aa###", "###aa###", "########", "########"],
        "sparkles.tv.fill": ["########", "#...a..#", "#.a...+#", "#....a.#", "#+.a...#", "########", "...##...", ".######."],
        "rectangle.3.group.fill": ["###.####", "###.####", "###.####", "........", "####.###", "####.###", "........", "aaaaaaaa"],
        "sun.max.fill": ["#..##..#", "........", "..####..", "#.#aa#.#", "#.#aa#.#", "..####..", "........", "#..##..#"],
        "location.fill": [".......#", ".....###", "...####.", ".######.", "....##..", "....##..", "....#...", "........"],
        "chevron.left.forwardslash.chevron.right": ["........", "........", ".#...a#.", "#...a..#", "#..a...#", ".#a...#.", "........", "........"],
        "info": ["...##...", "........", "..###...", "...##...", "...##...", "...##...", "..####..", "........"],
        "drop.fill": ["...#....", "...##...", "..####..", ".##a###.", ".#a####.", ".######.", "..####..", "........"],
        "bolt.fill": ["....###.", "...###..", "..###...", ".######.", "...###..", "..###...", ".##.....", "#......."],
        "wand.and.stars": ["a.....a.", "...a....", ".....##.", "....##..", "...##...", "..##..a.", ".##.....", "##......"],
        "square.grid.3x3.fill": ["##.##.##", "##.##.##", "........", "##.aa.##", "##.aa.##", "........", "##.##.##", "##.##.##"],
        "square.on.square": ["#####...", "#...#...", "#.aaaaa.", "#.a#..a.", "###...a.", "..a...a.", "..aaaaa.", "........"],
        "sun.and.horizon": ["........", "..#..#..", "...aa...", ".#aaaa#.", "..aaaa..", "########", "........", ".######."],
        "cloud.sun": ["..a.....", ".aaa.a..", "aaa##...", ".a####..", ".######.", "########", "########", "........"],
        "antenna.radiowaves.left.and.right": ["#..##..#", "#.#..#.#", "#.#aa#.#", "#.#aa#.#", "...##...", "...##...", "...##...", "..####.."],
        "power": ["...##...", ".#.##.#.", "#..##..#", "#..##..#", "#......#", "#......#", ".#....#.", "..####.."],
        "location.north.line": ["...##...", "..####..", ".######.", "...##...", "...##...", "...##...", "........", "aaaaaaaa"],
        "xmark": ["##....##", ".##..##.", "..####..", "...##...", "..####..", ".##..##.", "##....##", "........"],
    ]
    static func has(_ symbol: String) -> Bool { rows[symbol] != nil }
}

struct PixelIcon: View {
    let symbol: String
    var accent: Color = Look.accent
    var size: CGFloat = 20

    var body: some View {
        let rows = PixelIcons.rows[symbol] ?? PixelIcons.rows["square.grid.3x3.fill"]!
        Canvas { ctx, sz in
            let n = CGFloat(rows.count)
            let b = floor(min(sz.width, sz.height) / n * 2) / 2
            let ox = (sz.width - b * n) / 2, oy = (sz.height - b * n) / 2
            let grid = rows.map(Array.init)
            func at(_ x: Int, _ y: Int) -> Character? {
                guard y >= 0, y < grid.count, x >= 0, x < grid[y].count, grid[y][x] != "." else { return nil }
                return grid[y][x]
            }
            let lift = max(1, b * 0.35)
            // The shadow the raised pixels cast on the wall.
            var shadow = Path()
            for (y, r) in grid.enumerated() { for (x, c) in r.enumerated() where c != "." {
                shadow.addRect(CGRect(x: ox + CGFloat(x) * b + lift * 0.5, y: oy + CGFloat(y) * b + lift * 0.75, width: b + 0.5, height: b + 0.5))
            } }
            ctx.fill(shadow, with: .color(.black.opacity(0.45)))
            for (y, r) in grid.enumerated() { for (x, c) in r.enumerated() where c != "." {
                let up = at(x, y - 1) == nil, lf = at(x - 1, y) == nil
                let dn = at(x, y + 1) == nil, rt = at(x + 1, y) == nil
                let base: Color = c == "a" ? accent : (c == "+" ? Color(white: 0.55) : Color(white: 0.93))
                let rect = CGRect(x: ox + CGFloat(x) * b - lift * 0.3, y: oy + CGFloat(y) * b - lift * 0.5, width: b + 0.5, height: b + 0.5)
                ctx.fill(Path(rect), with: .color(base))
                if up || lf { ctx.fill(Path(rect), with: .color(.white.opacity(0.14))) }
                else if dn || rt { ctx.fill(Path(rect), with: .color(.black.opacity(0.18))) }
                if up { ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0.75, b * 0.18))),
                                 with: .color(.white.opacity(0.6))) }
            } }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}
