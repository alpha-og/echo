import SwiftUI
import AVKit

/// System output picker (AirPlay / Bluetooth). Presented with the standard
/// route button; no custom device list to maintain.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        view.activeTintColor = .white
        view.tintColor = .white
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
