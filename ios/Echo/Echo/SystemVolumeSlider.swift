import SwiftUI
import MediaPlayer

/// System output volume slider. There is no setter API for system volume;
/// `MPVolumeView` is the sanctioned control.
struct SystemVolumeSlider: UIViewRepresentable {
    var tint: Color

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        view.tintColor = UIColor(tint)
    }
}
