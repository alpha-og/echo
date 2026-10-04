import SwiftUI

/// Connection, background, and pairing controls. Opened from the gear icon;
/// the player screen keeps only the status dot.
struct SettingsView: View {
    @ObservedObject var reporter: NowPlayingReporter
    @Environment(\.dismiss) private var dismiss

    private var accent: Color {
        reporter.artworkAccent.map(Color.init(uiColor:)) ?? .accentColor
    }

    /// Pastels are darkened so white text holds contrast on any cover tint.
    private var buttonTint: Color {
        guard let ui = reporter.artworkAccent else { return .accentColor }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        if 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6 {
            return Color(uiColor: UIColor(red: r * 0.55, green: g * 0.55, blue: b * 0.55, alpha: 1))
        }
        return accent
    }

    private var statusText: String {
        reporter.connected ? "Live" : reporter.connecting ? "Connecting" : "Offline"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Relay")
                        Spacer()
                        Text(reporter.host.isEmpty ? "—" : reporter.host)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if reporter.connected {
                        Button("Disconnect", role: .destructive) {
                            reporter.disconnect()
                        }
                    } else {
                        Button(reporter.connecting ? "Connecting…" : "Connect") {
                            reporter.connect()
                        }
                        .disabled(reporter.connecting)
                    }
                } header: {
                    Text("Connection")
                }

                Section {
                    Toggle("Stay connected in background", isOn: $reporter.keepAlive)
                        .tint(accent)
                } header: {
                    Text("Background")
                } footer: {
                    Text(reporter.keepAlive
                         ? "Keeps sync live when locked (silent audio, extra battery)."
                         : "iOS suspends sync shortly after leaving the app.")
                }

                Section {
                    Button("Unpair this Mac", role: .destructive) {
                        reporter.unpair()
                        dismiss()
                    }
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("Removes the session here and on the relay. Pair again to reconnect.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(buttonTint)
    }
}
