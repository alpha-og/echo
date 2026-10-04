import AppKit
import Foundation
import UniformTypeIdentifiers

/// macOS Music.app, driven over AppleScript (`osascript` child process).
/// Fuzzy metadata only: AppleScript exposes no catalog store IDs, so Mac
/// snapshots never carry `store_id` — exact handoff stays iPhone-led.
///
/// Explicitly nonisolated: the blocking `osascript` invocations must stay
/// off the main actor, and nothing here touches UI state.
enum MusicApp {
    struct State {
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let position: Double
        let playing: Bool
        let present: Bool
    }

    /// One `osascript` invocation; nil on any failure (app closed, timeout).
    nonisolated private static func run(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        // Never hang the UI on a busy Music.app.
        let deadline = Date(timeIntervalSinceNow: 5)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        guard let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        let out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Current Mac playback, or `present: false` when Music is idle/closed.
    nonisolated static func query() -> State {
        let src = """
            tell application "Music"
                if it is running then
                    try
                        set t to current track
                        return (name of t & "\\n" & artist of t & "\\n" & album of t & "\\n" & (duration of t as string) & "\\n" & (player position as string) & "\\n" & (player state as string))
                    end try
                end if
            end tell
            """
        guard let out = run(src) else {
            return State(title: "", artist: "", album: "", duration: 0, position: 0, playing: false, present: false)
        }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 6 else {
            return State(title: "", artist: "", album: "", duration: 0, position: 0, playing: false, present: false)
        }
        return State(
            title: parts[0], artist: parts[1], album: parts[2],
            duration: Double(parts[3]) ?? 0,
            position: Double(parts[4]) ?? 0,
            playing: parts[5] == "playing",
            present: true
        )
    }

    /// Album art via the public iTunes Search API (no auth needed).
    /// AppleScript `data of artwork` yields only an object reference for
    /// streamed tracks, so catalog search is the reliable path. Track-change
    /// only, downscaled into the 40KB frame budget. A missing cover is
    /// preferable to a wrong one: mismatches return nil.
    nonisolated static func coverArtwork(title: String, artist: String, maxBytes: Int = 40_000) async -> Data? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = comps?.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]], !results.isEmpty else { return nil }
            let norm = { (s: String) in
                s.lowercased()
                    .replacingOccurrences(of: "\\s*\\(.*?\\)", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            let wantTrack = norm(title), wantArtist = norm(artist).replacingOccurrences(of: " ", with: "")
            var best: [String: Any]?
            var bestScore = 0
            for r in results {
                let t = norm(r["trackName"] as? String ?? "")
                let a = norm(r["artistName"] as? String ?? "").replacingOccurrences(of: " ", with: "")
                var score = 0
                if t == wantTrack { score += 2 }
                if !wantArtist.isEmpty, (a.contains(wantArtist) || wantArtist.contains(a)) { score += 2 }
                if score > bestScore { bestScore = score; best = r }
            }
            guard bestScore >= 4, let pick = best,
                  var art = pick["artworkUrl100"] as? String else { return nil }
            // 100px is blurry at 192pt; Apple serves bigger on the same path.
            art = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let artURL = URL(string: art) else { return nil }
            let (imgData, _) = try await URLSession.shared.data(from: artURL)
            guard let img = NSImage(data: imgData),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            for edge in [192, 128] {
                // Explicit sRGB context: source art is often Display P3, and an
                // untagged re-encode displays oversaturated. Convert, don't strip.
                guard let ctx = CGContext(data: nil, width: edge, height: edge,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: srgb,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { continue }
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: edge, height: edge))
                guard let small = ctx.makeImage() else { continue }
                let destData = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(
                    destData, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dest, small,
                    [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { continue }
                let jpg = destData as Data
                if jpg.count <= maxBytes { return jpg }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Execute a relay command target. Returns false when Music can't comply.
    @discardableResult
    nonisolated static func execute(action: String, position: Double?) -> Bool {
        let cmd: String
        switch action {
        case "play": cmd = "play"
        case "pause": cmd = "pause"
        case "toggle":
            cmd = query().playing ? "pause" : "play"
        case "next": cmd = "next track"
        case "previous", "prev": cmd = "previous track"
        case "seek":
            guard let pos = position, pos.isFinite, pos >= 0 else { return false }
            cmd = "set player position to \(pos)"
        default: return false
        }
        return run("tell application \"Music\"\n\(cmd)\nend tell") != nil
    }
}
