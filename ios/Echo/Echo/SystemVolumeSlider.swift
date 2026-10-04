import SwiftUI
import Combine
import MediaPlayer
import AVFoundation

/// System output volume with the app's capsule styling. There is no setter
/// API for system volume, so a hidden `MPVolumeView` carries the drags:
/// the custom slider mirrors into its `UISlider`, which is the sanctioned
/// control path.
struct SystemVolumeSlider: View {
    var accent: Color

    @State private var level: Double = Double(AVAudioSession.sharedInstance().outputVolume)
    @State private var lastSet = Date.distantPast
    @State private var driver: MPVolumeView?

    /// Fresh lookup every drag: the slider subview may not exist on the
    /// first pass, so a cached lookup is allowed to stay nil forever.
    private func systemSlider() -> UISlider? {
        driver?.subviews.first(where: { $0 is UISlider }) as? UISlider
    }

    var body: some View {
        ZStack {
            VolumeDriver { driver = $0 }
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
            LevelSlider(
                value: level,
                accent: accent,
                onChanged: { v in
                    level = v
                    lastSet = Date()
                    systemSlider()?.value = Float(v)
                    systemSlider()?.sendActions(for: .valueChanged)
                }
            )
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            // Adopt hardware-button changes when idle. The 1s guard keeps
            // incoming state from fighting an active drag.
            let sys = Double(AVAudioSession.sharedInstance().outputVolume)
            if abs(sys - level) > 0.02, Date().timeIntervalSince(lastSet) > 1 {
                level = sys
            }
        }
    }
}

/// Hosts the hidden volume view. The caller looks up the slider on demand.
private struct VolumeDriver: UIViewRepresentable {
    var onHost: (MPVolumeView) -> Void

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        view.showsRouteButton = false
        view.alpha = 0.01
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        onHost(view)
    }
}
