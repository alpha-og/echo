import SwiftUI
import Combine

@main
struct EchoApp: App {
    @StateObject private var model = MenuModel()

    var body: some Scene {
        MenuBarExtra {
            menuContent
                .padding(12)
                .frame(width: 340)
        } label: {
            menuLabel
        }
        // Window style: the menu style dims every non-Button row into gray.
        .menuBarExtraStyle(.window)

        Window("Pairing", id: "pairing") {
            PairPopup(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private var menuLabel: some View {
        // Radiating waves read as an echo; cover art belongs in the panel.
        Image(systemName: "dot.radiowaves.left.and.right")
            .help(model.menuTitle)
    }

    @State private var tick = Date()

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            playerCluster
            Divider()
            deviceRow(title: formattedDeviceName(model.iphoneTrack?.deviceName ?? "iPhone"), side: .iphone, track: model.iphoneTrack)
            deviceRow(title: formattedDeviceName(model.macTrack?.deviceName ?? "This Mac"), side: .mac, track: model.macTrack)
            Divider()
            relayRow
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .background(PairWindowDriver(model: model))
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { t in
            tick = t
        }
    }

    private func clock(_ secs: Double) -> String {
        guard secs.isFinite, secs >= 0 else { return "0:00" }
        let total = Int(secs)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// Hostnames arrive as `Name-Model.local`. Present them as names.
    private func formattedDeviceName(_ raw: String) -> String {
        var s = raw
        if s.hasSuffix(".local") { s = String(s.dropLast(".local".count)) }
        if s == "This Mac" { return s }
        s = s.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let clean = s.split(separator: " ").filter { !$0.isEmpty }.joined(separator: " ")
        return clean.isEmpty ? raw : clean
    }

    private var playerCluster: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    if let img = model.track?.artwork {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.title2)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 3)
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(
                        text: model.track?.title ?? "Nothing playing",
                        font: .headline,
                        height: 24,
                        centered: false
                    )
                    .lineLimit(1)
                    MarqueeText(
                        text: model.track?.artist ?? "echo",
                        font: .subheadline,
                        height: 20,
                        centered: false
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 14) {
                    Button { Task { await model.sendToActive("previous") } } label: {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.track == nil)
                    Button {
                        Task { await model.sendToActive(model.track?.isPlaying == true ? "pause" : "play") }
                    } label: {
                        Image(systemName: model.track?.isPlaying == true ? "pause.fill" : "play.fill")
                            .font(.system(size: 26))
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.track == nil)
                    .keyboardShortcut("p")
                    Button { Task { await model.sendToActive("next") } } label: {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.track == nil)
                }
                .foregroundStyle(.primary)
            }
            let prog = model.displayProgress(now: tick)
            VStack(spacing: 2) {
                ProgressView(value: prog.fraction)
                    .controlSize(.small)
                    .tint(model.artworkTint.map(Color.init(nsColor:)) ?? .accentColor)
                HStack {
                    Button { model.handoffToMac() } label: {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.iphoneTrack?.storeID == nil)
                    .help("Handoff to Mac")
                    Spacer()
                    Text(prog.label)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }


    private var relayRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.relayOnline ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text("Relay")
                .font(.subheadline)
            Spacer()
            Group {
                if model.relayBusy {
                    ProgressView()
                        .controlSize(.small)
                } else if !model.relayOnline {
                    Button { model.startRelay() } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Start relay")
                } else {
                    Button { model.restartRelay() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Restart relay")
                    Button { model.stopRelay() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop relay")
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: model.relayOnline)
            .animation(.easeInOut(duration: 0.2), value: model.relayBusy)
        }
    }

    /// Owns the pairing popup. `openWindow` is only resolvable from inside
    /// a View hierarchy, hence this invisible driver view.
    private struct PairWindowDriver: View {
        @ObservedObject var model: MenuModel
        @Environment(\.openWindow) private var openWindow
        @Environment(\.dismissWindow) private var dismissWindow

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .onChange(of: model.pairPending) {
                    if model.pairPending {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "pairing")
                    } else {
                        dismissWindow(id: "pairing")
                    }
                }
        }
    }


    private func deviceRow(title: String, side: DeviceSide, track: BarTrack?) -> some View {
        let staleMs = track.map { Int64(Date().timeIntervalSince1970 * 1000) - $0.updatedMs } ?? 0
        let isStale = track != nil && staleMs > 15_000
        return Button {
            // Tap to take manual control; tap again for Auto.
            model.targetOverride = (model.targetOverride == side) ? nil : side
        } label: {
            HStack {
                Circle()
                    .fill(track?.isPlaying == true && !isStale ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline)
                        if side == model.effectiveTarget, track != nil, !isStale {
                            Text(model.targetOverride == nil ? "auto" : "manual")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                        } else if isStale {
                            Text("stale")
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2), in: Capsule())
                        }
                    }
                    if let t = track {
                        MarqueeText(
                            text: "\(t.title) — \(t.artist)",
                            font: .caption,
                            height: 16,
                            centered: false
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Idle")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if side == model.effectiveTarget, track != nil, !isStale {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(isStale ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .help(model.targetOverride == side ? "Back to Auto" : "Control \(title)")
    }
}

/// Pops when a phone taps this Mac. Live code + countdown; closes itself
/// when pairing completes, expires, or is cancelled on the phone.
struct PairPopup: View {
    @ObservedObject var model: MenuModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 14) {            Image(systemName: "iphone")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("\(model.pairDevice ?? "iPhone") wants to pair")
                .font(.headline)
                .multilineTextAlignment(.center)
            if let code = model.pairingCode {
                Text(code)
                    .font(.system(size: 40, weight: .bold).monospacedDigit())
                    .textSelection(.enabled)
                Text("Expires in \(model.pairingValidSec)s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView()
            }
            Button("Dismiss") { dismissWindow(id: "pairing") }
        }
        .padding(28)
        .frame(minWidth: 280)
        .onAppear {
            model.refreshPairCode()
            // Agent app has no dock presence: raise the popup explicitly.
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.windows.first(where: { $0.title == "Pairing" }) {
                w.level = .floating
                w.makeKeyAndOrderFront(nil)
            }
        }
    }
}
