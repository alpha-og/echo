import AppKit
import Combine
import CoreImage
import Darwin
import Foundation

/// Now-playing snapshot from the relay (`GET /status`) or local Music.app.
struct BarTrack {
    let title: String
    let artist: String
    let storeID: String?
    let duration: Double
    let position: Double
    let isPlaying: Bool
    let artwork: NSImage?
    /// Unix millis the snapshot was taken (freshness for the active rule).
    let updatedMs: Int64
    /// Unix millis this side polled it (display extrapolation starts here).
    let polledMs: Int64
}

/// Which side commands and display defer to. Mirrors `active_side` in
/// `src/protocol.rs`: whoever is playing wins; ties go to self.
enum DeviceSide {
    case iphone, mac
}

func activeSide(
    iphonePlaying: Bool, iphoneTs: Int64,
    macPlaying: Bool, macTs: Int64,
    nowMs: Int64, selfSide: DeviceSide
) -> DeviceSide {
    let stale: Int64 = 15_000
    let ip = iphonePlaying && nowMs - iphoneTs <= stale
    let mp = macPlaying && nowMs - macTs <= stale
    switch (ip, mp) {
    case (true, false): return .iphone
    case (false, true): return .mac
    default: return selfSide
    }
}

/// Polls the loopback relay (trusted, no token) and sends commands.
/// Owns the handoff-to-Mac path: exact `storeID` + position into Music.app.
@MainActor
final class MenuModel: ObservableObject {
    /// Per-side snapshots. `track` is the smart-active one for display.
    @Published var iphoneTrack: BarTrack?
    @Published var macTrack: BarTrack?
    @Published var relayOnline = false
    /// Cover-derived tint for the progress bar (nil = system accent).
    @Published var artworkTint: NSColor?
    /// A phone is asking to pair right now (drives the popup, not the menu).
    @Published var pairPending = false
    @Published var pairDevice: String?
    /// Latest pairing code, fetched only while a request is pending.
    @Published var pairingCode: String?
    /// Seconds until that code expires. Auto-refreshes at zero while pending.
    @Published var pairingValidSec: Int = 0

    private var countdown: Timer?

    /// Manual control target. nil = Auto (whoever is playing wins).
    @Published var targetOverride: DeviceSide?
    /// Last side seen playing. Ties (both paused) stick here instead of
    /// flipping to self — pausing the iPhone must not surface the Mac track.
    private var lastActiveSide: DeviceSide = .mac
    /// Side our transport last paused. A later play resumes here, not self.
    private var lastPausedSide: DeviceSide? {
        didSet {
            if let s = lastPausedSide {
                UserDefaults.standard.set(s == .mac ? "mac" : "iphone", forKey: "echo.lastPaused")
            } else {
                UserDefaults.standard.removeObject(forKey: "echo.lastPaused")
            }
        }
    }

    private var timer: Timer?
    private var relayProcess: Process?
    private var autoStarted = false
    private let bridge = NowPlayingBridge()
    /// When we last forwarded transport to the iPhone. If the Mac wakes up
    /// on its own inside this window (same keypress also delivered to
    /// Music.app, which we cannot unregister), it wasn't user intent.
    private var lastForwardedAt: Date?

    init() {
        if UserDefaults.standard.string(forKey: "echo.lastPaused") == "mac" {
            lastPausedSide = .mac
        } else if UserDefaults.standard.string(forKey: "echo.lastPaused") == "iphone" {
            lastPausedSide = .iphone
        }
        bridge.onCommand = { [weak self] action in
            Task { @MainActor [weak self] in await self?.systemCommand(action) }
        }
        // Quit takes any relay on our port with us, so no orphan keeps
        // serving after the menu app is gone.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.stopSpawnedRelay()
        }
        let poll = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
        Task { await refresh() }
    }

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var lastArtKey = ""
    private var lastArtB64: String?
    private var lastArtImage: NSImage?

    /// Smart-active side: whoever is playing; ties and silence stick to
    /// whoever played last (not self) so pause never flips the display.
    var activeSideNow: DeviceSide {
        let now = nowMs
        let stale: Int64 = 15_000
        let ip = (iphoneTrack?.isPlaying ?? false) && now - (iphoneTrack?.updatedMs ?? 0) <= stale
        let mp = (macTrack?.isPlaying ?? false) && now - (macTrack?.updatedMs ?? 0) <= stale
        switch (ip, mp) {
        case (true, false): return .iphone
        case (false, true): return .mac
        default: return lastActiveSide
        }
    }

    /// The track the menu shows and controls target.
    var track: BarTrack? {
        activeSideNow == .mac ? (macTrack ?? iphoneTrack) : (iphoneTrack ?? macTrack)
    }

    var menuTitle: String {
        guard let t = track else { return relayOnline ? "Nothing playing" : "echo offline" }
        return "\(t.title) — \(t.artist)"
    }

    func refresh() async {
        await refreshStatus()
        await refreshPairPending()
    }

    private func refreshStatus() async {
        // iPhone side over HTTP; Mac side straight from Music.app, concurrently.
        async let remote: (Data?, HTTPURLResponse?) = {
            guard let url = URL(string: "http://127.0.0.1:11447/status?role=iphone") else { return (nil, nil) }
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                return (data, resp as? HTTPURLResponse)
            } catch {
                return (nil, nil)
            }
        }()
        async let local = Task.detached { MusicApp.query() }.value
        let ((data, http), music) = await (remote, local)

        guard let http, let data else {
            relayOnline = false
            settleRelayTransition()
            iphoneTrack = nil
            bridge.update(track: nil)
            macTrack = music.present ? macTrackFrom(music) : nil
            macWS?.cancel(with: .goingAway, reason: nil)
            macWS = nil
            // Relay down and we haven't tried yet: launch the bundled copy once.
            if !autoStarted {
                autoStarted = true
                startRelay()
            }
            return
        }
        relayOnline = true
        settleRelayTransition()
        ensureMacWS()
        if http.statusCode == 204 {
            iphoneTrack = nil
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            iphoneTrack = BarTrack(
                title: obj["title"] as? String ?? "(no title)",
                artist: obj["artist"] as? String ?? "(no artist)",
                storeID: obj["store_id"] as? String,
                duration: obj["duration"] as? Double ?? 0,
                position: Self.effectivePosition(obj),
                isPlaying: (obj["state"] as? String) == "playing",
                artwork: (obj["artwork"] as? String).flatMap { b64 in
                    Data(base64Encoded: b64).flatMap(NSImage.init(data:))
                },
                updatedMs: (obj["timestamp_ms"] as? NSNumber)?.int64Value ?? nowMs,
                polledMs: nowMs
            )
        }
        if music.present {
            let fresh = macTrackFrom(music)
            let key = "\(fresh.title)\n\(fresh.artist)"
            if key != lastArtKey {
                // New track: drop old art, fetch anew.
                lastArtKey = key
                lastArtB64 = nil
                lastArtImage = nil
                macTrack = fresh
                Task.detached {
                    let jpg = await MusicApp.coverArtwork(title: fresh.title, artist: fresh.artist)
                    await MainActor.run { [weak self] in
                        guard let self, self.lastArtKey == key, let jpg else { return }
                        self.lastArtB64 = jpg.base64EncodedString()
                        self.lastArtImage = NSImage(data: jpg)
                        if let cur = self.macTrack {
                            self.macTrack = BarTrack(
                                title: cur.title, artist: cur.artist, storeID: cur.storeID,
                                duration: cur.duration, position: cur.position,
                                isPlaying: cur.isPlaying,
                                artwork: self.lastArtImage,
                                updatedMs: cur.updatedMs, polledMs: cur.polledMs
                            )
                        }
                        self.publishMac()
                    }
                }
            } else {
                // Same track: preserve fetched art across polls.
                macTrack = BarTrack(
                    title: fresh.title, artist: fresh.artist, storeID: fresh.storeID,
                    duration: fresh.duration, position: fresh.position,
                    isPlaying: fresh.isPlaying,
                    artwork: lastArtImage,
                    updatedMs: fresh.updatedMs, polledMs: fresh.polledMs
                )
            }
        } else {
            macTrack = nil
            lastArtKey = ""
            lastArtB64 = nil
            lastArtImage = nil
        }
        if let img = track?.artwork {
            artworkTint = Self.averageColor(img)
        } else {
            artworkTint = nil
        }
        // Latch the winner while exactly one side plays; ties keep the old
        // latch so the display doesn't flip on pause.
        let now = nowMs
        let ipPlaying = (iphoneTrack?.isPlaying ?? false) && now - (iphoneTrack?.updatedMs ?? 0) <= 15_000
        let macPlaying = (macTrack?.isPlaying ?? false) && now - (macTrack?.updatedMs ?? 0) <= 15_000
        if ipPlaying != macPlaying {
            lastActiveSide = ipPlaying ? .iphone : .mac
        } else if lastActiveSide == .iphone, iphoneTrack == nil, macTrack != nil {
            lastActiveSide = .mac
        } else if lastActiveSide == .mac, macTrack == nil, iphoneTrack != nil {
            lastActiveSide = .iphone
        }
        bridge.update(track: track)
        suppressKeyWake()
        publishMac()
    }

    /// Guardian: if the Mac woke up within ~3s of us forwarding transport to
    /// the iPhone, that wake was the keypress leaking into Music.app — undo it.
    /// Deliberate Mac plays (UI, handoff, mac-targeted keys) never arm the
    /// window, so they survive.
    private func suppressKeyWake() {
        guard let fwd = lastForwardedAt,
              Date().timeIntervalSince(fwd) < 3,
              macTrack?.isPlaying == true,
              iphoneTrack?.isPlaying == true else { return }
        lastForwardedAt = nil
        MusicApp.execute(action: "pause", position: nil)
    }

    private func macTrackFrom(_ m: MusicApp.State) -> BarTrack {
        BarTrack(title: m.title, artist: m.artist, storeID: nil,
                 duration: m.duration, position: m.position, isPlaying: m.playing,
                 artwork: nil, updatedMs: nowMs, polledMs: nowMs)
    }

    // MARK: - Mac publisher + command receiver (WS role=mac)

    private var macWS: URLSessionWebSocketTask?

    private func ensureMacWS() {
        guard macWS == nil,
              let url = URL(string: "ws://127.0.0.1:11447/ws?role=mac") else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        macWS = task
        task.resume()
        listenMac()
    }

    private func listenMac() {
        macWS?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let msg):
                    if case .string(let text) = msg { self.handleMacCommand(text) }
                    self.listenMac()
                case .failure:
                    self.macWS?.cancel(with: .goingAway, reason: nil)
                    self.macWS = nil
                }
            }
        }
    }

    private func handleMacCommand(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let action: String
        if let a = obj["action"] as? String { action = a }
        else if let inner = obj["Command"] as? [String: Any], let a = inner["action"] as? String { action = a }
        else { return }
        let pos = (obj["position"] as? NSNumber)?.doubleValue
        if MusicApp.execute(action: action, position: pos) {
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                await self.refreshStatus()
            }
        }
    }

    /// Publish this Mac's snapshot so the phone sees it as a device.
    private func publishMac() {
        guard let m = macTrack else { return }
        var snap: [String: Any] = [
            "title": m.title, "artist": m.artist, "album": "",
            "duration": m.duration, "elapsed": m.position,
            "rate": m.isPlaying ? 1.0 : 0.0,
            "state": m.isPlaying ? "playing" : "paused",
            "timestamp_ms": m.updatedMs, "origin": "mac",
            "device_name": ProcessInfo.processInfo.hostName,
        ]
        // Cover rides along only while it matches the current track.
        if let a = lastArtB64 { snap["artwork"] = a }
        guard let data = try? JSONSerialization.data(withJSONObject: snap),
              let text = String(data: data, encoding: .utf8) else { return }
        macWS?.send(.string(text)) { _ in }
    }

    // MARK: - Relay lifecycle

    private func bundledRelay() -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("echo"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Launch the bundled relay, clearing any stale relay first so there is
    /// exactly one owner of the port: this app.
    func startRelay() {
        relayBusy = true
        relayWanted = true
        relayWantedAt = Date()
        Task {
            Self.killAllRelays()
            _ = await Self.waitPortFree(timeoutMs: 3000)
            relayProcess = nil
            guard let bin = bundledRelay() else {
                NSLog("echo: no bundled relay binary found")
                await refresh()
                return
            }
            let p = Process()
            p.executableURL = bin
            p.arguments = ["serve", "--bind", "0.0.0.0:11447"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                relayProcess = p
                NSLog("echo: relay launched (pid %d)", p.processIdentifier)
            } catch {
                NSLog("echo: relay launch failed: %@", "\(error)")
                relayProcess = nil
            }
            await refresh()
        }
    }

    /// True from tap until the poll confirms the new state (or times out).
    /// Drives the spinner so Start/Stop/Restart feel instant.
    @Published var relayBusy = false
    private var relayWanted: Bool?
    private var relayWantedAt = Date.distantPast

    /// Whether this app launched the current relay (as opposed to finding
    /// one already serving the port).
    var relayManaged: Bool { relayProcess?.isRunning == true }

    /// PIDs of echo processes listening on our port (spawned or terminal).
    private static func relayPIDs() -> [Int32] {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", ":11447"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return [] }
        lsof.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func isEcho(pid: Int32) -> Bool {
        // Exact binary name only: a contains-match would also hit "Echo"
        // itself (it holds client sockets on :11447) and Stop would kill
        // the menu app instead of the relay.
        if pid == getpid() { return false }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return false }
        ps.waitUntilExit()
        let comm = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return comm == "echo"
    }

    /// Stop every echo relay on our port (spawned child or terminal leftover).
    /// Returns the PIDs signaled, for logging.
    @discardableResult
    private static func killAllRelays() -> [Int32] {
        let pids = relayPIDs().filter(isEcho(pid:))
        for pid in pids {
            kill(pid, SIGTERM)
        }
        if !pids.isEmpty {
            NSLog("echo: signaled relays %@", pids.map(String.init(describing:)).joined(separator: ","))
        }
        return pids
    }

    /// Block (off-main) until :11447 is free or the timeout lapses.
    private static func waitPortFree(timeoutMs: Int) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: Double(timeoutMs) / 1000)
        while Date() < deadline {
            let busy = relayPIDs().contains { isEcho(pid: $0) }
            if !busy { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return relayPIDs().contains { isEcho(pid: $0) } == false
    }

    func stopRelay() {
        relayBusy = true
        relayWanted = false
        relayWantedAt = Date()
        Task {
            relayProcess?.terminate()
            relayProcess = nil
            let killed = Self.killAllRelays()
            _ = await Self.waitPortFree(timeoutMs: 3000)
            NSLog("echo: stop done (signaled %d), port free", killed.count)
            await refresh()
        }
    }

    /// Clear the optimistic spinner once the poll confirms (or 8s passes).
    private func settleRelayTransition() {
        guard relayWanted != nil else { return }
        if relayOnline == relayWanted || Date().timeIntervalSince(relayWantedAt) > 8 {
            relayWanted = nil
            relayBusy = false
        }
    }

    /// Quit-time cleanup: no orphan relays. The menu owns the port while
    /// installed; a terminal `cargo run` can always start another after.
    func stopSpawnedRelay() {
        relayProcess?.terminate()
        relayProcess = nil
        Self.killAllRelays()
    }

    func restartRelay() {
        relayBusy = true
        relayWanted = true
        relayWantedAt = Date()
        // Bypass the once-per-launch guard: this is an explicit user action.
        autoStarted = true
        Task {
            Self.killAllRelays()
            _ = await Self.waitPortFree(timeoutMs: 3000)
            relayProcess = nil
            guard let bin = bundledRelay() else {
                NSLog("echo: no bundled relay binary found")
                await refresh()
                return
            }
            let p = Process()
            p.executableURL = bin
            p.arguments = ["serve", "--bind", "0.0.0.0:11447"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                relayProcess = p
                NSLog("echo: relay relaunched (pid %d)", p.processIdentifier)
            } catch {
                NSLog("echo: relay launch failed: %@", "\(error)")
                relayProcess = nil
            }
            await refresh()
        }
    }

    /// Run the bundled `echo pair-code` and surface the current code.
    func refreshPairCode() {
        guard let bin = bundledRelay() else {
            pairingCode = nil
            return
        }
        Task.detached { [weak self] in
            let p = Process()
            p.executableURL = bin
            p.arguments = ["pair-code"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                await MainActor.run { [weak self] in self?.pairingCode = nil }
                return
            }
            let out = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            // "pairing code: 123456  (valid 27s)" -> code + seconds.
            let nums = out.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .filter { !$0.isEmpty }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if nums.count >= 2, let secs = Int(nums[1]) {
                    self.pairingCode = nums[0]
                    self.pairingValidSec = secs
                    self.startCountdown()
                } else if nums.count == 1 {
                    self.pairingCode = nums[0]
                    self.pairingValidSec = 0
                } else {
                    self.pairingCode = nil
                    self.pairingValidSec = 0
                }
            }
        }
    }

    private func startCountdown() {
        countdown?.invalidate()
        // .common modes: a default-mode timer freezes while the menu is open.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.pairingValidSec > 0 {
                    self.pairingValidSec -= 1
                } else {
                    self.countdown?.invalidate()
                    self.refreshPairCode()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        countdown = t
    }

    /// Is a phone asking to pair? Polled alongside status; drives the popup.
    private func refreshPairPending() async {
        guard let url = URL(string: "http://127.0.0.1:11447/pair-requests") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let pending = (obj["pending"] as? Bool) ?? false
            let device = obj["device"] as? String
            if pending != pairPending || device != pairDevice {
                pairPending = pending
                pairDevice = device
                if pending {
                    refreshPairCode()
                } else {
                    pairingCode = nil
                    pairingValidSec = 0
                }
            }
        } catch {
            // Relay down: refresh() already reports that; stay quiet here.
        }
    }

    /// Live display progress for the 1s UI tick (extrapolated between polls).
    func displayProgress(now: Date = Date()) -> (fraction: Double, label: String) {
        guard let t = track, t.duration > 0 else { return (0, "--:-- / --:--") }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var pos = t.position
        if t.isPlaying {
            pos += Double(nowMs - t.polledMs) / 1000.0
        }
        pos = min(max(pos, 0), t.duration)
        return (pos / t.duration, "\(Self.clock(pos)) / \(Self.clock(t.duration))")
    }

    private static func clock(_ secs: Double) -> String {
        guard secs.isFinite, secs >= 0 else { return "0:00" }
        let total = Int(secs)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    private static func averageColor(_ img: NSImage) -> NSColor? {
        guard let tiff = img.tiffRepresentation,
              let ci = CIImage(data: tiff),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: ci,
                kCIInputExtentKey: CIVector(cgRect: ci.extent),
              ]),
              let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(out, toBitmap: &px, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        let r = CGFloat(px[0]) / 255, g = CGFloat(px[1]) / 255, b = CGFloat(px[2]) / 255
        // Too dark for a dark panel: fall back to the accent color.
        guard 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.08 else { return nil }
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }

    private static func effectivePosition(_ obj: [String: Any]) -> Double {        let base = obj["elapsed"] as? Double ?? 0
        let rate = (obj["rate"] as? NSNumber)?.doubleValue ?? 0
        let ts = (obj["timestamp_ms"] as? NSNumber)?.int64Value ?? 0
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let pos = base + (rate > 0 && (obj["state"] as? String) == "playing"
            ? Double(now - ts) / 1000 * rate : 0)
        let dur = obj["duration"] as? Double ?? 0
        return dur > 0 ? min(max(pos, 0), dur) : max(pos, 0)
    }

    func send(_ action: [String: Any]) async {
        guard let url = URL(string: "http://127.0.0.1:11447/command") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5
        req.httpBody = try? JSONSerialization.data(withJSONObject: action)
        _ = try? await URLSession.shared.data(for: req)
        await refresh()
    }

    /// Where transport goes: manual pick, else whoever is playing, else
    /// whatever we paused last (resume), else self.
    var effectiveTarget: DeviceSide {
        if let o = targetOverride { return o }
        let somethingPlaying = (iphoneTrack?.isPlaying ?? false) || (macTrack?.isPlaying ?? false)
        if somethingPlaying { return activeSideNow }
        return lastPausedSide ?? .mac
    }

    var targetLabel: String {
        switch targetOverride {
        case .iphone: return "iPhone"
        case .mac: return "This Mac"
        case nil:
            return activeSideNow == .mac ? "Auto (Mac)" : "Auto (iPhone)"
        }
    }

    func cycleTarget() {
        switch targetOverride {
        case nil: targetOverride = .iphone
        case .iphone: targetOverride = .mac
        case .mac: targetOverride = nil
        }
    }

    /// System media keys and menu transport go to the effective target.
    /// Takeover: commanding the iPhone while this Mac plays pauses the Mac
    /// first. A woken-up Mac is caught by the guardian in refreshStatus.
    func systemCommand(_ action: [String: Any]) async {
        let target = effectiveTarget
        let name = action["action"] as? String ?? ""
        if target == .mac {
            let pos = (action["position"] as? NSNumber)?.doubleValue
            if name == "pause" || (name == "toggle" && (macTrack?.isPlaying ?? false)) {
                lastPausedSide = .mac
            }
            MusicApp.execute(action: name, position: pos)
            await refreshStatus()
        } else {
            if name == "pause" || (name == "toggle" && (iphoneTrack?.isPlaying ?? false)) {
                lastPausedSide = .iphone
            } else if (macTrack?.isPlaying ?? false) {
                MusicApp.execute(action: "pause", position: nil)
            }
            lastForwardedAt = Date()
            await send(action)
        }
    }

    func sendToActive(_ actionName: String, position: Double? = nil) async {
        var action: [String: Any] = ["action": actionName]
        if let pos = position { action["position"] = pos }
        await systemCommand(action)
    }

    /// Play the phone's current track in Mac Music.app at the same position.
    func handoffToMac() {
        guard let t = iphoneTrack, let sid = t.storeID else { return }
        guard let url = URL(string: "https://music.apple.com/us/song/\(sid)?i=\(sid)") else { return }
        NSWorkspace.shared.open(url)
        // Music needs a moment to load the track before seeking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [pos = t.position] in
            let src = """
                tell application "Music"
                  try
                    set player position to \(pos)
                    play
                  end try
                end tell
                """
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
        }
    }
}
