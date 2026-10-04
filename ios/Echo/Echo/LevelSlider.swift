import SwiftUI

/// Capsule level control with the Scrubber's visuals. Drag position stays
/// local while the finger is down; `onChanged` fires live, `onEnded` once
/// on release for expensive endpoints.
struct LevelSlider: View {
    var value: Double
    var accent: Color
    var onChanged: (Double) -> Void
    var onEnded: ((Double) -> Void)?

    @State private var drag: Double?

    var body: some View {
        GeometryReader { geo in
            let shown = min(max(drag ?? value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(height: 6)
                Capsule()
                    .fill(accent)
                    .frame(width: geo.size.width * shown, height: 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = min(max(v.location.x / max(geo.size.width, 1), 0), 1)
                        drag = f
                        onChanged(f)
                    }
                    .onEnded { v in
                        let f = min(max(v.location.x / max(geo.size.width, 1), 0), 1)
                        drag = nil
                        (onEnded ?? onChanged)(f)
                    }
            )
        }
        .frame(height: 28)
    }
}
