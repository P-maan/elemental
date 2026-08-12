//  Updater.swift — keeping everybody on the current version.
//
//  Elemental is distributed as a .pkg from GitHub releases, which means that
//  without this, every install is frozen at whatever version it was downloaded
//  at. For an app given to family that is not a small problem: they will never
//  update, they will never say anything, and every bug fixed after the day they
//  installed it stays broken for them forever.
//
//  WHAT THIS DOES AND DOES NOT DO
//
//  It checks GitHub, compares versions, downloads the new package and hands it
//  to the system installer. What it deliberately does NOT do is install silently
//  behind the user's back, and that is a limitation of the platform rather than
//  a choice about how much to trust them:
//
//    A .pkg lays its payload into /Applications, which is root-owned. Installing
//    it needs administrator rights. An app can only obtain those without asking
//    by shipping a privileged helper tool blessed by SMJobBless — a separate
//    root daemon, a launchd plist, a matching pair of code-signing requirements,
//    and a Developer ID to sign both halves with. That is a serious amount of
//    attack surface to add to a wallpaper, and this build is not even signed.
//
//  So the flow is: check quietly, download quietly, and then ask once. The user
//  sees one dialog and one authentication prompt, which is the same thing every
//  other unsigned Mac app does, and nothing happens to their machine without
//  them saying yes.
//
//  Everything degrades. No network, a rate-limited API, a malformed release, a
//  download that stops half way — all of them leave the app running exactly as
//  it was. An updater that can break the thing it updates is worse than none.

import Foundation

/// A version like "0.1" or "1.12.3", comparable properly.
///
/// String comparison is wrong here in a way that bites late rather than early:
/// "0.10" sorts BEFORE "0.9" lexically, so the first release past 0.9 would
/// silently stop offering itself and every install would sit there believing it
/// was current. Compared component by component as integers instead.
struct SemVer: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ raw: String) {
        // Tags are conventionally "v0.1"; the bundle string is "0.1".
        let s = raw.hasPrefix("v") || raw.hasPrefix("V") ? String(raw.dropFirst()) : raw
        let bits = s.split(separator: ".").map { String($0) }
        guard !bits.isEmpty else { return nil }
        var out: [Int] = []
        for b in bits {
            // Tolerate "1.2.3-beta.4" by taking the numeric head of each part.
            let digits = b.prefix { $0.isNumber }
            guard let n = Int(digits) else { break }
            out.append(n)
        }
        guard !out.isEmpty else { return nil }
        parts = out
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

/// A release newer than the one running.
struct AvailableUpdate: Equatable {
    var version: SemVer
    var notes: String
    var packageURL: URL
    var bytes: Int

    static func == (a: AvailableUpdate, b: AvailableUpdate) -> Bool {
        a.version.description == b.version.description
    }
}

enum Updater {

    /// Where releases live. The repository is public, so these calls are
    /// unauthenticated and subject to GitHub's 60-requests-an-hour limit for an
    /// IP — which is why the check interval below is hours and not minutes.
    static let releasesAPI = URL(string: "https://api.github.com/repos/P-maan/elemental/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/P-maan/elemental/releases/latest")!

    /// The version this binary was built as.
    static var currentVersion: SemVer {
        let s = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return SemVer(s ?? "0") ?? SemVer("0")!
    }

    // MARK: - Checking

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// Ask GitHub what the newest release is. Nil means "nothing to do" for any
    /// reason at all — offline, rate limited, malformed, or simply current.
    static func check() async -> AvailableUpdate? {
        var req = URLRequest(url: releasesAPI)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        // GitHub asks for this and rate-limits harder without it.
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Elemental/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rel = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        // A draft is not published and a prerelease is not for everybody's
        // parents. Neither should ever be offered automatically.
        guard rel.draft != true, rel.prerelease != true else { return nil }
        guard let newest = SemVer(rel.tag_name), newest > currentVersion else { return nil }
        // The .pkg is the artifact that can actually install itself. A release
        // carrying only the saver zip is not an update we can apply.
        guard let asset = rel.assets.first(where: { $0.name.hasSuffix(".pkg") }) else { return nil }

        return AvailableUpdate(version: newest,
                               notes: rel.body ?? "",
                               packageURL: asset.browser_download_url,
                               bytes: asset.size)
    }

    // MARK: - Downloading

    /// Fetch the package to a temporary file. Returns nil on any failure.
    ///
    /// The size is checked against what the release advertised. That is not a
    /// security control — anyone who could substitute the payload could
    /// substitute the manifest — it is a corruption check, and it is the only
    /// integrity check available for an unsigned build. Once the package is
    /// signed with a Developer ID, `installer` verifies the signature itself and
    /// refuses a tampered one, which is the real answer.
    static func download(_ update: AvailableUpdate) async -> URL? {
        var req = URLRequest(url: update.packageURL)
        req.timeoutInterval = 120
        guard let (tmp, resp) = try? await URLSession.shared.download(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Elemental-\(update.version).pkg")
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return nil }

        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, abs(size - update.bytes) < 4096 else {
            NSLog("Elemental: update download is %d bytes, expected %d — discarding",
                  size, update.bytes)
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        return dest
    }

    /// How often to look. Hours, not minutes: the API is unauthenticated and
    /// rate limited per IP, and a wallpaper checking for updates more often than
    /// it checks the weather would be absurd.
    static let checkInterval: TimeInterval = 6 * 3600
}
