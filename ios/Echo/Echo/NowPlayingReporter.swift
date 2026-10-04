import Foundation
import MediaPlayer
import Combine
import UIKit
import CoreImage
import Network
import BackgroundTasks

/// Publishes systemMusicPlayer Now Playing to the Rust relay over WS,
/// and executes Commands (play/pause/next/prev/seek/playStoreID) from Mac.
///
/// Wire protocol matches `src/protocol.rs`:
///   iPhone -> relay: {"title":..,"artist":..,"store_id":..,"elapsed":..,"rate":..,"state":"playing",...}
///   relay -> iPhone: {"action":"pause"} / {"action":"seek","position":12.5} / ...
/// A Mac snapshot received over the relay (origin=mac).
struct MacSnapshot: Equatable {
    let title: String
    let artist: String
    let state: String
    let isPlaying: Bool
    let position: Double
    let duration: Double
    let deviceName: String
    let updatedMs: Int64
    /// Cover bytes when the relay has them (sticky across heartbeats).
    let artwork: Data?
    /// Cover-derived accent, mirroring the local player.
    var accent: UIColor? { Self.averageColor(data: artwork) }

    private static func averageColor(data: Data?) -> UIColor? {
        guard let data, let img = UIImage(data: data),
              let ci = CIImage(image: img),
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
        guard 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.08 else { return nil }
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    static func == (lhs: MacSnapshot, rhs: MacSnapshot) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.state == rhs.state
            && lhs.position == rhs.position && lhs.duration == rhs.duration
            && lhs.deviceName == rhs.deviceName && lhs.updatedMs == rhs.updatedMs
            && lhs.artwork == rhs.artwork
    }

    var isStale: Bool {
        Int64(Date().timeIntervalSince1970 * 1000) - updatedMs > 15_000
    }
}

@MainActor
final class NowPlayingReporter: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "echo.host") ?? ""
    @Published var pairCode = ""
    @Published var connected = false
    @Published var connecting = false
    @Published var statusLine = "(not connected)"
    @Published var storeID: String?
    @Published var logTail = ""
    /// Local playback progress for the progress bar (exact, no extrapolation).
    @Published var progress: Double = 0
    @Published var timeLabel = ""
    /// Silent-audio hold while backgrounded (sideload-only, battery cost).
    @Published var keepAlive = UserDefaults.standard.object(forKey: "echo.keepalive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAlive, forKey: "echo.keepalive") }
    }
    let audioHold = AudioKeepalive()

    /// Session token from `/pair`, persisted so pairing is type-once.
    @Published private(set) var sessionToken: String? = UserDefaults.standard.string(forKey: "echo.token") {
        didSet {
            let p = sessionToken != nil
            if paired != p { paired = p }
        }
    }
    /// Stored rather than computed: SwiftUI only observes stored properties,
    /// so a computed flag would leave the player/discovery switch stale.
    @Published var paired = UserDefaults.standard.string(forKey: "echo.token") != nil
    /// Last command received from Mac, shown as a transient pill (nil = hidden).
    @Published var lastCommand: String?
    /// Monotonic trigger for haptics. `lastCommand` alone is unsuitable —
    /// it also changes on auto-dismiss, which would double-fire feedback.
    @Published var commandSeq = 0
    /// Current album art (refreshed only on track change, ~192px).
    @Published var artwork: UIImage?
    /// Average cover color for subtle accents (nil = system accent).
    @Published var artworkAccent: UIColor?
    /// Mac snapshot from the relay (nil = Mac unseen/offline).
    @Published var mac: MacSnapshot?
    /// Last Mac device name seen, kept after the snapshot expires so
    /// titles never fall back to a generic label.
    @Published var lastMacName: String?
    /// Incremented on pairing failure; the code field shakes on change.
    @Published var pairShake = 0
    var isIdle: Bool { !connected && storeID == nil }
    var playerIsPlaying: Bool { player.playbackState == .playing }

    /// Smart-active side: whoever is playing wins; ties stick to whoever
    /// played last, so pausing the Mac never flips the iPhone UI to itself.
    var macIsActive: Bool {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let stale: Int64 = 15_000
        let mePlaying = (player.playbackState == .playing)
        let macPlaying = (mac?.state == "playing") && (now - (mac?.updatedMs ?? 0) <= stale)
        if mePlaying != macPlaying { return macPlaying }
        return lastActiveWasMac
    }
    /// Latched winner; flipped only while exactly one side plays.
    private var lastActiveWasMac = false

    private var lastArtworkKey: String?
    private var artworkB64: String?
    private var wasLocallyPlaying = false

    private var commandGen = 0

    private var ws: URLSessionWebSocketTask?
    private var player: MPMusicPlayerController { .systemMusicPlayer }
    private var heartbeatTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var reconnectTask: Task<Void, Never>?
    /// Set by an explicit Disconnect tap; cleared by Connect or launch.
    private var suppressAuto = false
    private var retryAttempt = 0
    private var pathMonitor: NWPathMonitor?
    private var monitorQueue: DispatchQueue?
    private var networkOK = true
    /// Timestamp of the last takeover in either direction. A 3s cooldown
    /// suppresses control loops between the two sides.
    private var lastTakeoverMs: Int64 = 0
    /// Last inbound command — takeover never fires within 3s of one.
    private var lastCommandMs: Int64 = 0

    private var wsURL: URL? {
        guard let tok = sessionToken, !normalizedHost().isEmpty else { return nil }
        return URL(string: "ws://\(normalizedHost())/ws?role=iphone&token=\(tok)")
    }

    private func normalizedHost() -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
            .replacingOccurrences(of: "/.*$", with: "", options: .regularExpression)
    }

    /// Reconnect with backoff (2s/5s/15s/30s), gated on network + user intent.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        guard !suppressAuto, paired else { return }
        retryAttempt += 1
        let delay: UInt64 = [2, 5, 15, 30][min(retryAttempt - 1, 3)]
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.suppressAuto, self.paired,
                  !self.connected, !self.connecting, self.networkOK else { return }
            self.log("reconnecting…")
            self.connect()
        }
    }

    /// Connect on launch / foreground when a pairing exists.
    func connectIfPaired() {
        if paired, !connected, !connecting, !suppressAuto, networkOK {
            retryAttempt = 0
            connect()
        }
    }

    /// Foreground/background hooks from the scene. Background starts the
    /// silent-audio hold (if toggled) and publishes once immediately so a
    /// lock-screen pause isn't stuck showing "playing" on the Mac.
    func enterBackground() {
        if keepAlive { audioHold.start() } else { audioHold.stop() }
        publish()
        scheduleBGRefresh()
    }

    func enterForeground() {
        audioHold.stop()
        publish()
        connectIfPaired()
    }

    private func scheduleBGRefresh() {
        guard paired else { return }
        let req = BGAppRefreshTaskRequest(identifier: "com.echo.refresh")
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        BGTaskScheduler.shared.submitTaskRequest(req, completionHandler: { _ in })
    }

    func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let q = DispatchQueue(label: "echo.path")
        monitorQueue = q
        let m = NWPathMonitor()
        pathMonitor = m
        m.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ok = path.status == .satisfied
                let was = self.networkOK
                self.networkOK = ok
                if !ok {
                    self.log("offline — waiting for network")
                } else if !was {
                    self.log("network back")
                    self.connectIfPaired()
                }
            }
        }
        m.start(queue: q)
    }
    /// Best-effort presence ping: on failure there is simply no popup, and
    /// manual code entry still works.
    func pairRequest(cancel: Bool) {
        let h = normalizedHost()
        guard !h.isEmpty, let url = URL(string: "http://\(h)/pair-requests") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        if cancel {
            req.httpMethod = "DELETE"
        } else {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["device": UIDevice.current.name])
        }
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    /// Type the 6-digit code shown on the Mac; store the session token.
    func pair() async {
        let h = normalizedHost()
        let code = pairCode.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[ -]", with: "", options: .regularExpression);
        guard !h.isEmpty, code.count == 6, code.allSatisfy({ $0.isNumber }) else {
            log("enter host + 6-digit code"); return
        }
        guard let url = URL(string: "http://\(h)/pair") else { log("bad host"); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { log("pair: no response"); return }
            if http.statusCode == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tok = obj["token"] as? String, !tok.isEmpty {
                sessionToken = tok
                UserDefaults.standard.set(h, forKey: "echo.host")
                UserDefaults.standard.set(tok, forKey: "echo.token")
                pairCode = ""
                log("paired with \(h)")
                connect()
            } else if http.statusCode == 429 {
                pairShake += 1
                log("pair: throttled, wait 5 min")
            } else {
                pairShake += 1
                log("pair rejected (\(http.statusCode))")
            }
        } catch {
            pairShake += 1
            log("pair: \(error.localizedDescription)")
        }
    }

    func unpair() {
        // Revoke server-side first so the relay invalidates the session,
        // then wipe local state.
        if let tok = sessionToken {
            let h = normalizedHost()
            if !h.isEmpty, let url = URL(string: "http://\(h)/sessions") {
                var req = URLRequest(url: url)
                req.httpMethod = "DELETE"
                req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 8
                URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
            }
        }
        disconnect(silent: true)
        sessionToken = nil
        mac = nil
        UserDefaults.standard.removeObject(forKey: "echo.token")
        log("unpaired")
    }

    func connect() {
        suppressAuto = false
        reconnectTask?.cancel()
        guard sessionToken != nil else {
            log("pair first"); return
        }
        guard networkOK else { log("offline — will connect when network returns"); return }
        guard !connecting && !connected else { return }
        connecting = true
        // The relay may no longer recognize this token (state reset or
        // revoked elsewhere). Discard it and return to discovery rather
        // than retrying a dead credential indefinitely.
        Task { [weak self] in
            guard let self else { return }
            if await self.tokenAlive() {
                self.retryAttempt = 0
                self.openSocket()
            } else {
                await MainActor.run {
                    self.connecting = false
                    self.sessionToken = nil
                    UserDefaults.standard.removeObject(forKey: "echo.token")
                    self.log("session expired — pair again")
                }
            }
        }
    }

    private func tokenAlive() async -> Bool {
        let h = normalizedHost()
        guard let tok = sessionToken, !h.isEmpty,
              let url = URL(string: "http://\(h)/status") else { return false }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode != 401
        } catch {
            // A network failure says nothing about the token; keep it and retry.
            return true
        }
    }

    private func openSocket() {
        guard let url = wsURL else {
            connecting = false
            log("pair first"); return
        }
        disconnect(silent: true)
        connecting = true
        let task = URLSession.shared.webSocketTask(with: url)
        ws = task
        task.resume()

        player.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemChanged),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player)
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged),
            name: .MPMusicPlayerControllerPlaybackStateDidChange, object: player)

        publish()
        // Structured-concurrency heartbeat: Timer-based polling is suspended
        // with the app in the background. 2s cadence against the relay's
        // 30s snapshot expiry keeps presence fresh without busy-looping.
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self.connected || self.connecting else { break }
                self.publish()
            }
        }
        // Mark live on the first successful ping, not on socket creation:
        // a failed handshake must read as Offline, never flicker Live first.
        ws?.sendPing { [weak self] err in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if err == nil {
                    self.connected = true
                    self.connecting = false
                    self.retryAttempt = 0
                    self.log("connected \(url.host ?? "?")")
                } else {
                    self.connecting = false
                    self.connected = false
                    self.scheduleReconnect()
                }
            }
        }
        listen()
    }

    func disconnect(silent: Bool = false) {
        if !silent { suppressAuto = true }
        reconnectTask?.cancel()
        heartbeatTask?.cancel(); heartbeatTask = nil
        NotificationCenter.default.removeObserver(self)
        player.endGeneratingPlaybackNotifications()
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        connecting = false
        if !silent { connected = false; log("disconnected") }
    }

    @objc private func itemChanged() { publish() }
    @objc private func stateChanged() { publish() }

    private func refreshArtwork(item: MPMediaItem?) {
        guard let art = item?.value(forProperty: MPMediaItemPropertyArtwork) as? MPMediaItemArtwork else {
            setArtwork(nil, nil)
            return
        }
        // Fallback chain: prefer a smaller cover over none, inside the
        // 40KB frame budget.
        for (edge, quality) in [(512, 0.55), (320, 0.5), (192, 0.5), (128, 0.4)] {
            if let img = art.image(at: CGSize(width: CGFloat(edge), height: CGFloat(edge))),
               let data = img.jpegData(compressionQuality: quality),
               data.count <= 40_000 {
                setArtwork(UIImage(data: data), data.base64EncodedString())
                return
            }
        }
        log("artwork skipped (too large even at 128px)")
        setArtwork(nil, nil)
    }

    private func setArtwork(_ img: UIImage?, _ b64: String?) {
        artwork = img
        artworkB64 = b64
        artworkAccent = img.flatMap(Self.averageColor)
    }

    private static func clock(_ secs: Double) -> String {
        guard secs.isFinite, secs >= 0 else { return "0:00" }
        let total = Int(secs)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    private static func averageColor(_ img: UIImage) -> UIColor? {
        guard let ci = CIImage(image: img),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: ci,
                kCIInputExtentKey: CIVector(cgRect: ci.extent),
              ]),
              let out = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(out, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        return UIColor(red: CGFloat(pixel[0]) / 255,
                       green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255,
                       alpha: 1)
    }

    private func snapshot() -> [String: Any] {
        let item = player.nowPlayingItem
        let state: String
        switch player.playbackState {
        case .playing: state = "playing"
        case .paused: state = "paused"
        case .stopped: state = "stopped"
        default: state = "unknown"
        }
        let rate: Double = (player.playbackState == .playing) ? Double(player.currentPlaybackRate) : 0
        var d: [String: Any] = [
            "state": state,
            "rate": rate,
            "elapsed": player.currentPlaybackTime.isFinite ? player.currentPlaybackTime : 0,
            "timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "device_name": UIDevice.current.name,
            "origin": "iphone",
        ]
        if let item {
            if let v = item.value(forProperty: MPMediaItemPropertyTitle) as? String { d["title"] = v }
            if let v = item.value(forProperty: MPMediaItemPropertyArtist) as? String { d["artist"] = v }
            if let v = item.value(forProperty: MPMediaItemPropertyAlbumTitle) as? String { d["album"] = v }
            if let v = item.value(forProperty: MPMediaItemPropertyPlaybackDuration) as? NSNumber { d["duration"] = v.doubleValue }
            if let v = item.value(forProperty: MPMediaItemPropertyPlaybackStoreID) as? String { d["store_id"] = v }
        }
        return d
    }

    private func publish() {
        let item = player.nowPlayingItem
        let sid = item?.value(forProperty: MPMediaItemPropertyPlaybackStoreID) as? String
        // Track changed: refresh cover once (never per-second).
        let isNewTrack = sid != lastArtworkKey
        if isNewTrack {
            lastArtworkKey = sid
            refreshArtwork(item: item)
        }
        // Takeover: this phone started playing while the Mac snapshot is
        // fresh and playing — pause the Mac. Fires once per playback
        // transition. Guards: 8s snapshot freshness, 3s cooldown since any
        // takeover or inbound command, live socket.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let locallyPlaying = player.playbackState == .playing
        if locallyPlaying, !wasLocallyPlaying, let m = mac, connected {
            let macFresh = nowMs - m.updatedMs <= 8_000
            let cooled = nowMs - lastTakeoverMs > 3_000 && nowMs - lastCommandMs > 3_000
            if m.isPlaying, macFresh, cooled {
                lastTakeoverMs = nowMs
                sendToMac("pause")
            }
        }
        wasLocallyPlaying = locallyPlaying
        updateActiveLatch()
        var snap = snapshot()
        // Artwork rides along only on the track-change publish (~20KB, not every second).
        if isNewTrack, let b64 = artworkB64 {
            snap["artwork"] = b64
        }
        let line = "\(snap["title"] as? String ?? "?") — \(snap["artist"] as? String ?? "?")"
        // Publish runs continuously; assign only on change to avoid
        // redundant view updates on identical state.
        if line != statusLine { statusLine = line }
        if sid != storeID { storeID = sid }
        let elapsed = snap["elapsed"] as? Double ?? 0
        let duration = snap["duration"] as? Double ?? 0
        progress = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
        let label = "\(Self.clock(elapsed)) / \(Self.clock(duration))"
        if label != timeLabel { timeLabel = label }
        guard let data = try? JSONSerialization.data(withJSONObject: snap),
              let text = String(data: data, encoding: .utf8) else { return }
        ws?.send(.string(text)) { [weak self] err in
            if let err { Task { @MainActor [weak self] in self?.log("send: \(err.localizedDescription)") } }
        }
    }

    private func listen() {
        ws?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let msg):
                    if case .string(let text) = msg { self.handleIncoming(text) }
                    self.listen()
                case .failure(let err):
                    self.log("ws closed: \(err.localizedDescription)")
                    self.connected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    /// Relay traffic: Mac states update the Mac card; commands addressed here execute.
    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type_ = obj["type"] as? String
        let origin = (obj["origin"] as? String) ?? ""
        if type_ == "state" || (type_ == nil && origin == "mac") {
            if origin == "mac" { ingestMac(obj) }
            return
        }
        handleCommand(text)
    }

    private func ingestMac(_ obj: [String: Any]) {
        let state = obj["state"] as? String ?? "unknown"
        let deviceName = obj["device_name"] as? String ?? "Mac"
        if !deviceName.isEmpty { lastMacName = deviceName }
        mac = MacSnapshot(
            title: obj["title"] as? String ?? "(no title)",
            artist: obj["artist"] as? String ?? "(no artist)",
            state: state,
            isPlaying: state == "playing",
            position: obj["elapsed"] as? Double ?? 0,
            duration: obj["duration"] as? Double ?? 0,
            deviceName: obj["device_name"] as? String ?? "Mac",
            updatedMs: (obj["timestamp_ms"] as? NSNumber)?.int64Value
                ?? Int64(Date().timeIntervalSince1970 * 1000),
            artwork: (obj["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
        )
        updateActiveLatch()
    }

    /// Latch the winner while exactly one side plays; ties keep the latch.
    private func updateActiveLatch() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let mePlaying = (player.playbackState == .playing)
        let macPlaying = (mac?.state == "playing") && (now - (mac?.updatedMs ?? 0) <= 15_000)
        if mePlaying != macPlaying {
            lastActiveWasMac = macPlaying
        }
    }

    /// Control the Mac from here (target=mac). Takeover mirrors the Mac
    /// side: if this phone is playing, pause it first so the Mac becomes
    /// the only player.
    func sendToMac(_ action: String) {
        // The local pause is the takeover itself: record it so publish()
        // does not answer with a reciprocal pause.
        if action != "pause", player.playbackState == .playing {
            player.pause()
            lastTakeoverMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
        guard let data = try? JSONSerialization.data(withJSONObject:
                ["type": "command", "action": action, "target": "mac"]),
              let text = String(data: data, encoding: .utf8) else { return }
        ws?.send(.string(text)) { _ in }
    }

    /// Local transport (the iPhone side of the segmented player).
    func localTransport(_ action: String) {
        switch action {
        case "play": player.play()
        case "pause": player.pause()
        case "toggle":
            player.playbackState == .playing ? player.pause() : player.play()
        case "next": player.skipToNextItem()
        case "previous", "prev": player.skipToPreviousItem()
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.publish() }
    }

    /// Live local progress for the 0.5s display tick.
    func localProgress() -> (fraction: Double, label: String) {
        let elapsed = player.currentPlaybackTime
        let duration = (player.nowPlayingItem?.value(
            forProperty: MPMediaItemPropertyPlaybackDuration) as? NSNumber)?.doubleValue ?? 0
        guard elapsed.isFinite, duration > 0 else { return (0, "--:-- / --:--") }
        return (min(max(elapsed / duration, 0), 1),
                "\(Self.clock(elapsed)) / \(Self.clock(duration))")
    }

    /// Mac progress extrapolated from its snapshot (elapsed + rate × age).
    func macProgress(now: Date = Date()) -> (fraction: Double, label: String) {
        guard let m = mac else { return (0, "--:-- / --:--") }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var pos = m.position
        if m.isPlaying {
            pos += Double(nowMs - m.updatedMs) / 1000.0
        }
        pos = max(pos, 0)
        let dur = m.duration
        let frac = dur > 0 ? min(pos / dur, 1) : 0
        return (frac, "\(Self.clock(pos)) / \(Self.clock(dur))")
    }

    /// Drop the Mac card after 30s without a snapshot (relay or menu app
    /// quit). Snapshots arrive every ~2s.
    func pruneStaleMac(now: Date = Date()) {
        if let m = mac,
           Int64(now.timeIntervalSince1970 * 1000) - m.updatedMs > 30_000 {
            mac = nil
        }
    }

    private func handleCommand(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Accept both {"action":..} and {"type":"command","action":..}
        let action: String
        if let a = obj["action"] as? String { action = a }
        else if let inner = obj["Command"] as? [String: Any], let a = inner["action"] as? String { action = a }
        else { return }
        let pos = (obj["position"] as? NSNumber)?.doubleValue
        let sid = obj["store_id"] as? String
        // Defense in depth: relay validates too, but never execute an
        // off-spec store_id/position on the phone.
        if let p = pos, !(p.isFinite && p >= 0 && p <= 86400) { return }
        if let s = sid, !(s.count <= 20 && s.allSatisfy({ $0.isNumber && $0.isASCII })) { return }
        lastCommandMs = Int64(Date().timeIntervalSince1970 * 1000)
        wasLocallyPlaying = player.playbackState == .playing
        flashCommand(label(for: action))
        switch action {
        case "play": player.play()
        case "pause": player.pause()
        case "toggle":
            player.playbackState == .playing ? player.pause() : player.play()
        case "next": player.skipToNextItem()
        case "previous", "prev": player.skipToPreviousItem()
        case "seek":
            if let pos { player.currentPlaybackTime = pos }
        case "play_store_id":
            guard let sid else { return }
            player.setQueue(with: [sid])
            player.currentPlaybackTime = pos ?? 0
            player.play()
        default: break
        }
        // Report back immediately so the Mac observes the change without
        // waiting for the next heartbeat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.publish() }
    }

    private func label(for action: String) -> String {
        switch action {
        case "play": return "Playing from Mac"
        case "pause": return "Paused from Mac"
        case "toggle": return "Toggled from Mac"
        case "next": return "Next track from Mac"
        case "previous", "prev": return "Previous track from Mac"
        case "seek": return "Seeked from Mac"
        case "play_store_id": return "Handoff from Mac"
        default: return "Command from Mac"
        }
    }

    private func flashCommand(_ text: String) {
        log("cmd \(text)")
        commandGen += 1
        let g = commandGen
        lastCommand = text
        commandSeq += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard let self, self.commandGen == g else { return }
            self.lastCommand = nil
        }
    }

    private func log(_ msg: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(msg)\n"
        logTail = String((logTail + line).suffix(2000))
    }

    /// BGAppRefresh entry: open the socket just long enough to push one
    /// snapshot, then close. No-op when unpaired or offline.
    func publishOneShotForBackground() {
        guard paired, networkOK, !suppressAuto else { return }
        connect()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.publish()
            try? await Task.sleep(for: .seconds(2))
            if self?.audioHold.running != true {
                self?.disconnect(silent: true)
            }
        }
    }
}
