import SwiftUI

/// Draggable progress bar. Seeks once on release; the drag position stays
/// local so snapshots never fight the finger.
struct Scrubber: View {
    var fraction: Double
    var accent: Color
    var onSeek: (Double) -> Void

    var body: some View {
        LevelSlider(
            value: fraction,
            accent: accent,
            onChanged: { _ in },
            onEnded: onSeek
        )
    }
}
