import SwiftUI
import Combine

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
    @State private var manualSide: Side?
    @State private var manualAt = Date.distantPast
    @State private var tick = Date()
    @State private var stableSide: Side = .iphone
    @State private var stableSince = Date()
    @State private var showSettings = false
    init(reporter: NowPlayingReporter, browser: EchoBrowser) {
        self.reporter = reporter as ReporterShim
        self._browser = ObservedObject(wrappedValue: browser)
    }

    enum Side: String, CaseIterable {
        case iphone = "iPhone"
        case mac = "Mac"
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

    private var effectiveSide: Side {
        if let m = manualSide,
           (m == settledAutoSide || Date().timeIntervalSince(manualAt) < 12) {
            return m
        }
        return settledAutoSide
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
                    .navigationTitle("Connect")
            }
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
        VStack(spacing: 16) {
            Picker("Device", selection: Binding(
                get: { effectiveSide },
                set: { manualSide = $0; manualAt = Date() }
            )) {
                ForEach(Side.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .onChange(of: autoSide) {
                // Hysteresis bookkeeping: only adopt the new auto side after
                // it holds; manual picks win for 12s.
                if autoSide != stableSide {
                    if Date().timeIntervalSince(stableSince) >= 3 {
                        stableSide = autoSide
                        stableSince = Date()
                    }
                } else {
                    stableSince = Date()
                }
                if let m = manualSide, m != settledAutoSide,
                   Date().timeIntervalSince(manualAt) >= 12 {
                    manualSide = nil
                }
            }
            if effectiveSide == .mac {
                macPlayer
            } else {
                localPlayer
            }
        }
        .padding(28)
        .background {
            if effectiveSide == .iphone {
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: effectiveSide)
        .sensoryFeedback(.impact(weight: .light), trigger: reporter.commandSeq)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { t in
            tick = t
            reporter.pruneStaleMac(now: t)
        }
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
        List {
            Section("Nearby Macs") {
                if browser.echoes.isEmpty {
                    HStack(spacing: 8) {
                        if browser.browsing { ProgressView().controlSize(.small) }
                        Text(browser.browsing ? "Looking…" : "No Macs found")
                            .foregroundStyle(.secondary)
                    }
                    Text("Start the relay on your Mac first")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(browser.echoes) { echo in
                        Button {
                            reporter.host = "\(echo.host):\(echo.port)"
                            selectedEcho = echo
                        } label: {
                            Label(echo.name, systemImage: "desktopcomputer")
                        }
                    }
                }
            }
            Section {
                Button("Enter address manually") { showManual = true }
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
