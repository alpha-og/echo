import SwiftUI
import Combine
import UIKit

@main
struct EchoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var reporter = NowPlayingReporter()
    @StateObject private var browser = EchoBrowser()

    var body: some Scene {
        WindowGroup {
            ContentView(reporter: reporter, browser: browser)
                .onAppear { reporter.startNetworkMonitor() }
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                reporter.enterForeground()
            case .background:
                reporter.enterBackground()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh("com.echo.refresh")) {
            // A force-quit app cannot run. This covers OS-suspended refresh
            // only: wake, publish one snapshot if paired, sleep again.
            await MainActor.run { reporter.publishOneShotForBackground() }
        }
    }
}

struct ContentView: View {
    @ObservedObject var reporter: ReporterShim
    @ObservedObject var browser: EchoBrowser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedEcho: DiscoveredEcho?
    @State private var showManual = false
    @State private var tick = Date()
    @State private var stableSide: Side = .iphone
    @State private var stableSince = Date()
    @State private var showSettings = false
    @AppStorage("echo.onboarded") private var onboarded = false
    init(reporter: NowPlayingReporter, browser: EchoBrowser) {
        self.reporter = reporter as ReporterShim
        self._browser = ObservedObject(wrappedValue: browser)
    }

    enum Side: String, CaseIterable, Identifiable {
        case iphone = "iPhone"
        case mac = "Mac"

        var id: String { rawValue }
    }

    private var autoSide: Side { reporter.macIsActive ? .mac : .iphone }

    /// Hysteresis: the auto side must hold for 3s before the UI follows it,
    /// so one stale snapshot can't flip the picker back and forth.
    private var settledAutoSide: Side {
        let now = Date()
        if autoSide != stableSide, now.timeIntervalSince(stableSince) >= 3 {
            return autoSide
        }
        return autoSide == stableSide ? autoSide : stableSide
    }

    @State private var expandedSide: Side?

    /// Display order: active side first. Hysteresis keeps the order from
    /// flipping on a single stale snapshot.
    private var orderedSides: [Side] {
        let other: Side = settledAutoSide == .mac ? .iphone : .mac
        return [settledAutoSide, other]
    }

    private var accent: Color {
        reporter.artworkAccent.map(Color.init(uiColor:)) ?? .accentColor
    }

    var body: some View {
        NavigationStack {
            if reporter.paired {
                playerView
                    .navigationTitle("echo")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Circle()
                                .fill(reporter.connected ? Color.green
                                      : reporter.connecting ? Color.orange : Color.red)
                                .frame(width: 8, height: 8)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showSettings = true } label: {
                                Image(systemName: "gear")
                            }
                        }
                    }
            } else {
                discoveryList
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { !reporter.paired && !onboarded },
                set: { if !$0 { onboarded = true } }
            )
        ) {
            OnboardingView { onboarded = true }
        }
        .sheet(item: $selectedEcho) { echo in
            PairSheet(echo: echo, reporter: reporter)
        }
        .sheet(isPresented: $showManual) {
            ManualSheet(reporter: reporter)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(reporter: reporter)
        }
        .onAppear {
            if !reporter.paired {
                browser.start()
            } else {
                reporter.connectIfPaired()
            }
        }
        .onChange(of: autoSide) {
            // Hysteresis bookkeeping: only adopt the new auto side for
            // ordering after it holds for 3s.
            if autoSide != stableSide {
                if Date().timeIntervalSince(stableSince) >= 3 {
                    stableSide = autoSide
                    stableSince = Date()
                }
            } else {
                stableSince = Date()
            }
        }
        .onChange(of: reporter.paired) {
            if reporter.paired {
                browser.stop()
            } else {
                browser.start()
            }
        }
    }

    // MARK: - Player

    private var playerView: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(Array(orderedSides.enumerated()), id: \.element) { i, side in
                    deviceCard(side: side, active: i == 0)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .background {
            if settledAutoSide == .iphone {
                ZStack {
                    if let img = reporter.artwork {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 80)
                            .opacity(0.4)
                            .ignoresSafeArea()
                    }
                }
            } else if let data = reporter.mac?.artwork, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(0.4)
                    .ignoresSafeArea()
            }
        }
        .overlay(alignment: .bottom) { commandPill }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: settledAutoSide)
        .sensoryFeedback(.impact(weight: .light), trigger: reporter.commandSeq)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { t in
            tick = t
            reporter.pruneStaleMac(now: t)
        }
        .navigationDestination(item: $expandedSide) { side in
            expandedPlayer(side: side)
        }
    }

    /// Compact per-device card: cover, titles, progress, transport.
    /// The active side sorts first and carries a live pill instead of chrome.
    private func deviceCard(side: Side, active: Bool) -> some View {
        Button { expandedSide = side } label: {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    cardCover(side: side)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(cardEyebrow(side: side))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer()
                            if active, cardIsPlaying(side: side) {
                                livePill
                            }
                        }
                        MarqueeText(
                            text: cardTitle(side: side),
                            font: .headline,
                            height: 24,
                            centered: false
                        )
                        .foregroundStyle(.primary)
                        Text(cardSubtitle(side: side))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(cardDetails(side: side))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                ProgressView(value: cardProgress(side: side))
                    .controlSize(.small)
                    .tint(cardAccent(side: side))
                HStack(spacing: 22) {
                    Button { cardTransport(side: side, "previous") } label: {
                        Image(systemName: "backward.fill")
                            .font(.body)
                    }
                    Button { cardTransport(side: side, "toggle") } label: {
                        Image(systemName: cardIsPlaying(side: side) ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                    }
                    Button { cardTransport(side: side, "next") } label: {
                        Image(systemName: "forward.fill")
                            .font(.body)
                    }
                    Spacer()
                    Text(cardTimeLabel(side: side))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
                .disabled(!cardHasTrack(side: side))
            }
            .padding(16)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    /// Pulsing "Now Playing" marker on the active card. Static under
    /// Reduce Motion.
    private var livePill: some View {
        HStack(spacing: 5) {
            PulsingDot()
            Text("Now Playing")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Hostnames arrive as `Name-Model.local`. Present them as names.
    private func formattedDeviceName(_ raw: String) -> String {
        var s = raw
        if s.hasSuffix(".local") { s = String(s.dropLast(".local".count)) }
        s = s.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return s.split(separator: " ").filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func cardCover(side: Side) -> some View {
        Group {
            if let img = cardArtwork(side: side) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12))
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func cardArtwork(side: Side) -> UIImage? {
        if side == .iphone {
            return reporter.artwork
        }
        return reporter.mac?.artwork.flatMap(UIImage.init(data:))
    }

    private func cardTitle(side: Side) -> String {
        if side == .iphone {
            return reporter.isIdle ? "Nothing playing" : reporter.statusLine
        }
        return reporter.mac?.title ?? "Waiting for Mac"
    }

    private func cardEyebrow(side: Side) -> String {
        if side == .iphone {
            return formattedDeviceName(UIDevice.current.name).uppercased()
        }
        return formattedDeviceName(reporter.mac?.deviceName ?? "Mac").uppercased()
    }

    private func cardSubtitle(side: Side) -> String {
        if side == .iphone {
            return reporter.isIdle ? "Play Apple Music on this iPhone" : "This iPhone"
        }
        guard let m = reporter.mac else { return "Play Music.app on your Mac" }
        return m.artist + (m.isStale ? " · stale" : "")
    }

    private func cardDetails(side: Side) -> String {
        if side == .iphone {
            return reporter.isIdle ? "Apple Music · idle" : "Apple Music · " + cardTimeLabel(side: side)
        }
        guard let m = reporter.mac else { return "Apple Music · idle" }
        return "Apple Music · " + cardTimeLabel(side: side) + (m.isPlaying ? " · playing" : " · paused")
    }

    private func cardTimeLabel(side: Side) -> String {
        side == .iphone ? reporter.localProgress().label : reporter.macProgress(now: tick).label
    }

    private func cardProgress(side: Side) -> Double {
        side == .iphone ? reporter.localProgress().fraction : reporter.macProgress(now: tick).fraction
    }

    private func cardAccent(side: Side) -> Color {
        if side == .iphone { return accent }
        return reporter.mac?.accent.map(Color.init(uiColor:)) ?? .accentColor
    }

    private func cardIsPlaying(side: Side) -> Bool {
        side == .iphone ? reporter.playerIsPlaying : (reporter.mac?.isPlaying ?? false)
    }

    private func cardHasTrack(side: Side) -> Bool {
        side == .iphone ? !reporter.isIdle : reporter.mac != nil
    }

    private func cardTransport(side: Side, _ action: String) {
        if side == .iphone {
            reporter.localTransport(action)
            return
        }
        guard let m = reporter.mac else { return }
        if action == "toggle" {
            reporter.sendToMac(m.isPlaying ? "pause" : "play")
        } else {
            reporter.sendToMac(action)
        }
    }

    /// Full player page for the tapped card.
    private func expandedPlayer(side: Side) -> some View {
        Group {
            if side == .mac {
                macPlayer
            } else {
                localPlayer
            }
        }
        .padding(28)
        .navigationTitle(side.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var localPlayer: some View {
        VStack(spacing: 8) {
            coverView
            if reporter.isIdle {
                Text("Nothing playing")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Play Apple Music on this iPhone")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            } else {
                let lp = reporter.localProgress()
                trackView
                ProgressView(value: lp.fraction)
                    .tint(accent)
                    .frame(maxWidth: 240)
                Text(lp.label)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            transportRow(
                isPlaying: reporter.playerIsPlaying,
                onToggle: { reporter.localTransport("toggle") },
                onPrev: { reporter.localTransport("previous") },
                onNext: { reporter.localTransport("next") }
            )
        }
    }

    private var macPlayer: some View {
        VStack(spacing: 8) {
            if let m = reporter.mac {
                Group {
                    if let data = m.artwork, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.secondary.opacity(0.12))
                    }
                }
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .shadow(radius: 12)
                .id("\(m.title)\n\(m.artist)")
                .transition(.opacity)
                MarqueeText(
                    text: m.title,
                    font: .title2.weight(.semibold),
                    height: 30
                )
                .multilineTextAlignment(.center)
                .lineLimit(2)
                MarqueeText(
                    text: m.deviceName + " · " + m.artist + (m.isStale ? " · stale" : ""),
                    font: .subheadline,
                    height: 22
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                let prog = reporter.macProgress(now: tick)
                ProgressView(value: prog.fraction)
                    .tint(m.accent.map(Color.init(uiColor:)) ?? .accentColor)
                    .frame(maxWidth: 240)
                Text(prog.label)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                transportRow(
                    isPlaying: m.isPlaying,
                    onToggle: { reporter.sendToMac(m.isPlaying ? "pause" : "play") },
                    onPrev: { reporter.sendToMac("previous") },
                    onNext: { reporter.sendToMac("next") }
                )
            } else {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                    .frame(width: 192, height: 160)
                Text("Waiting for Mac")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Play something in Music.app — it appears here")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func transportRow(
        isPlaying: Bool,
        onToggle: @escaping () -> Void,
        onPrev: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 36) {
            Button(action: onPrev) { Image(systemName: "backward.fill").font(.title2) }
            Button(action: onToggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
            }
            Button(action: onNext) { Image(systemName: "forward.fill").font(.title2) }
        }
        .foregroundStyle(.primary)
        .padding(.top, 4)
    }

    private var coverView: some View {
        Group {
            if let img = reporter.artwork {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12))
            }
        }
        .frame(width: 300, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .shadow(radius: 12)
        .id(reporter.storeID ?? "none")
        .transition(.opacity)
    }

    private var trackView: some View {
        MarqueeText(
            text: reporter.statusLine,
            font: .title2.weight(.semibold),
            height: 30
        )
        .foregroundStyle(reporter.isIdle ? .secondary : .primary)
    }

    @ViewBuilder
    private var commandPill: some View {
        if let cmd = reporter.lastCommand {
            Text(cmd)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 8)
        }
    }

    // MARK: - Discovery

    private var discoveryList: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 96, height: 96)
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                    Text("Connect to your Mac")
                        .font(.title2.weight(.bold))
                    Text("Pick a nearby Mac to pair. Make sure Echo is running on it and both devices share the same Wi-Fi.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.top, 32)

                if browser.echoes.isEmpty {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            if browser.browsing {
                                ProgressView().controlSize(.small)
                            }
                            Text(browser.browsing ? "Looking for Macs…" : "No Macs found")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        Text("Start the relay on your Mac first")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 10) {
                        ForEach(browser.echoes) { echo in
                            Button {
                                reporter.host = "\(echo.host):\(echo.port)"
                                selectedEcho = echo
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, height: 44)
                                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(echo.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text("\(echo.host):\(echo.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(12)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                Button("Enter address manually") { showManual = true }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 32)
            }
        }
    }
}

// MARK: - Sheets

struct PairSheet: View {
    let echo: DiscoveredEcho
    @ObservedObject var reporter: ReporterShim
    @Environment(\.dismiss) private var dismiss
    @State private var showError = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 96, height: 96)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    Text("Pair with \(echo.name)")
                        .font(.title2.weight(.semibold))
                    Text("Enter the 6-digit code shown in the menu bar app")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                OTPCodeView(code: $reporter.pairCode, shakeTrigger: reporter.pairShake) {
                    Task { await reporter.pair() }
                }
                if showError {
                    Text("Incorrect code — check the Mac and try again")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .transition(.opacity)
                }
                Button("Pair") { Task { await reporter.pair() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(reporter.pairCode.count < 6)
                Spacer()
                Spacer()
            }
            .padding(28)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        reporter.pairCode = ""
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.success, trigger: reporter.paired)
        .onChange(of: reporter.pairShake) { showError = true }
        .onChange(of: reporter.pairCode) { showError = false }
        .onChange(of: reporter.paired) {
            if reporter.paired { dismiss() }
        }
        .onAppear { reporter.pairRequest(cancel: false) }
        .onDisappear { reporter.pairRequest(cancel: true) }
    }
}

struct ManualSheet: View {
    @ObservedObject var reporter: ReporterShim
    @Environment(\.dismiss) private var dismiss
    @State private var showError = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Mac 192.168.1.2:11447", text: $reporter.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                } header: {
                    Text("Mac address")
                } footer: {
                    Text("Only needed when Nearby Macs finds nothing (guest WiFi).")
                }
                Section {
                    OTPCodeView(code: $reporter.pairCode, shakeTrigger: reporter.pairShake) {
                        Task {
                            await reporter.pair()
                            if reporter.paired { dismiss() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                    if showError {
                        Text("Incorrect code — check the Mac and try again")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Pairing code")
                }
                Section {
                    Button("Pair") {
                        Task {
                            await reporter.pair()
                            if reporter.paired { dismiss() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .disabled(reporter.pairCode.count < 6 || reporter.host.isEmpty)
                }
            }
            .navigationTitle("Manual setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        reporter.pairCode = ""
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: reporter.pairShake) { showError = true }
        .onChange(of: reporter.pairCode) { showError = false }
        .onAppear { reporter.pairRequest(cancel: false) }
        .onDisappear { reporter.pairRequest(cancel: true) }
    }
}

// Concrete reporter type used by ContentView (aliased for previews).
typealias ReporterShim = NowPlayingReporter
