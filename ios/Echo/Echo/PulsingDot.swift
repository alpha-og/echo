import SwiftUI

/// Live indicator dot: gentle pulse while playing, static under Reduce
/// Motion or when paused.
struct PulsingDot: View {
    var playing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowing = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 7, height: 7)
            .opacity(!playing || reduceMotion ? 0.85 : (glowing ? 1 : 0.35))
            .animation(
                !playing || reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: glowing
            )
            .onAppear { glowing = true }
            .onChange(of: playing) { glowing = playing }
    }
}
