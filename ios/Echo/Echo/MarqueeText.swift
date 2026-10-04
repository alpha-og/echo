import SwiftUI

/// Single-line text in the Music.app style: static and truncated when it
/// fits, scrolling when it overflows. Honors Reduce Motion (static always).
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var height: CGFloat = 22
    var centered = true
    var speed: CGFloat = 40 // pt/s

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var scrolling = false

    var body: some View {
        GeometryReader { geo in
            if reduceMotion || !(textWidth > geo.size.width && geo.size.width > 0) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .frame(width: geo.size.width, alignment: centered ? .center : .leading)
            } else {
                Text(text)
                    .font(font)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: scrolling ? -(textWidth - geo.size.width) : 0)
                    .mask(edgeFade(width: geo.size.width))
                    .onAppear { startScroll(distance: textWidth - geo.size.width) }
            }
        }
        .frame(height: height)
        .background(measurer)
        .onPreferenceChange(WidthKey.self) { textWidth = $0 }
        .onChange(of: text) {
            scrolling = false
            textWidth = 0
        }
    }

    /// Intrinsic text width, measured outside any constraining frame so
    /// overflow is detected correctly.
    private var measurer: some View {
        Text(text)
            .font(font)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: WidthKey.self, value: g.size.width)
                }
            )
            .opacity(0)
            .allowsHitTesting(false)
    }

    private func startScroll(distance: CGFloat) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation(
                .linear(duration: max(3, distance / speed))
                .repeatForever(autoreverses: true)
            ) {
                scrolling = true
            }
        }
    }

    private func edgeFade(width: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 12 / width),
                .init(color: .black, location: (width - 12) / width),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct WidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
