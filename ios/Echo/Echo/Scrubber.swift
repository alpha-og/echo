import SwiftUI

/// Draggable progress bar. The drag position stays local while the finger
/// is down; the seek fires once on release so snapshots never fight it.
struct Scrubber: View {
    var fraction: Double
    var accent: Color
    var onSeek: (Double) -> Void

    @State private var drag: Double?

    var body: some View {
        GeometryReader { geo in
            let shown = min(max(drag ?? fraction, 0), 1)
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
                        drag = min(max(v.location.x / max(geo.size.width, 1), 0), 1)
                    }
                    .onEnded { v in
                        let f = min(max(v.location.x / max(geo.size.width, 1), 0), 1)
                        drag = nil
                        onSeek(f)
                    }
            )
        }
        .frame(height: 28)
    }
}
