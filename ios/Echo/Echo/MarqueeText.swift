import SwiftUI

/// Single-line text in the Music.app style: static and truncated when it
/// fits, scrolling when it overflows. Scroll position derives from wall
/// time, so playback state or re-renders can never stall it mid-scroll.
/// Honors Reduce Motion (static always).
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var height: CGFloat = 22
    var centered = true
    var speed: CGFloat = 40 // pt/s
    var leadPause: TimeInterval = 1.2
    var tailPause: TimeInterval = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var startDate = Date()

    var body: some View {
        GeometryReader { geo in
            if reduceMotion || !(textWidth > geo.size.width && geo.size.width > 0) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .frame(width: geo.size.width, alignment: centered ? .center : .leading)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                    Text(text)
                        .font(font)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: -Self.offset(
                            elapsed: startDate.distance(to: context.date),
                            distance: textWidth - geo.size.width,
                            speed: speed,
                            leadPause: leadPause,
                            tailPause: tailPause
                        ))
                        .mask(edgeFade(width: geo.size.width))
                }
            }
        }
        .frame(height: height)
        .background(measurer)
        .onPreferenceChange(WidthKey.self) { textWidth = $0 }
        .onChange(of: text) {
            textWidth = 0
            startDate = Date()
        }
    }

    /// Ping-pong scroll position for an elapsed time: hold, traverse,
    /// hold, return. Pure function of its inputs.
    static func offset(
        elapsed: TimeInterval,
        distance: CGFloat,
        speed: CGFloat,
        leadPause: TimeInterval,
        tailPause: TimeInterval
    ) -> CGFloat {
        let travel = max(0.1, Double(distance) / Double(speed))
        let cycle = leadPause + travel + tailPause + travel
        let t = elapsed.truncatingRemainder(dividingBy: cycle)
        if t < leadPause { return 0 }
        let t1 = t - leadPause
        if t1 < travel { return distance * CGFloat(t1 / travel) }
        let t2 = t1 - travel
        if t2 < tailPause { return distance }
        let t3 = t2 - tailPause
        return distance * CGFloat(1 - t3 / travel)
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
