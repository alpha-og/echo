import SwiftUI

/// First-run pages: what Echo is, what the Mac needs, how pairing works.
/// Shown once, before the Connect page. Dismissal persists a flag.
struct OnboardingView: View {
    var onDone: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages: [(symbol: String, title: String, body: String)] = [
        (
            "dot.radiowaves.left.and.right",
            "Your music, everywhere",
            "Echo mirrors Apple Music between this iPhone and your Mac. Live Now Playing, transport both ways, exact handoff."
        ),
        (
            "desktopcomputer",
            "Start with your Mac",
            "Run Echo on your Mac so the relay is up, and join the same Wi-Fi on both devices. No accounts, no cloud."
        ),
        (
            "number",
            "Pair once",
            "Pick your Mac below and type the 6-digit code it shows. The session persists, so this happens exactly once."
        ),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.09, blue: 0.15), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            Circle()
                .fill(Color.blue.opacity(0.25))
                .frame(width: 320, height: 320)
                .blur(radius: 100)
                .offset(x: 120, y: -220)
            Circle()
                .fill(Color.purple.opacity(0.2))
                .frame(width: 280, height: 280)
                .blur(radius: 100)
                .offset(x: -140, y: 240)

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        VStack(spacing: 20) {
                            Spacer()
                            ZStack {
                                Circle()
                                    .fill(.white.opacity(0.08))
                                    .frame(width: 120, height: 120)
                                Image(systemName: pages[i].symbol)
                                    .font(.system(size: 48, weight: .light))
                                    .foregroundStyle(.white)
                            }
                            Text(pages[i].title)
                                .font(.title.weight(.bold))
                                .foregroundStyle(.white)
                            Text(pages[i].body)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 36)
                            Spacer()
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(reduceMotion ? nil : .easeInOut, value: page)

                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? Color.white : Color.white.opacity(0.3))
                            .frame(width: i == page ? 24 : 8, height: 8)
                            .animation(reduceMotion ? nil : .easeInOut, value: page)
                    }
                }
                .padding(.bottom, 28)

                Button(page == pages.count - 1 ? "Get Started" : "Continue") {
                    if page == pages.count - 1 {
                        onDone()
                    } else {
                        page += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.white)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 36)
                .padding(.bottom, 12)

                if page < pages.count - 1 {
                    Button("Skip") { onDone() }
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 40)
                } else {
                    Spacer().frame(height: 40 + 20)
                }
            }
        }
    }
}
