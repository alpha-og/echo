import AVFoundation
import Foundation

/// Silent-audio keepalive: holds the process alive while backgrounded so the
/// relay WebSocket survives lock / app-switch.
///
/// Why this exists: this app is not the audio source (Music.app is), so the
/// `audio` background mode alone does nothing. Playing inaudible audio with
/// `.mixWithOthers` keeps our socket alive without ducking music.
///
/// Personal sideload only: App Store review rejects silent audio. Gated
/// behind the "Stay connected" toggle, off = previous behavior.
final class AudioKeepalive {
    private var engine: AVAudioEngine?
    private(set) var running = false
    private let queue = DispatchQueue(label: "echo.audio-hold")

    func start() {
        queue.async { [weak self] in
            guard let self, self.engine == nil else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, options: [.mixWithOthers])
                try session.setActive(true)
            } catch {
                NSLog("echo: audio session failed: \(error)")
                return
            }
            let e = AVAudioEngine()
            let output = e.outputNode
            let format = output.inputFormat(forBus: 0)
            let src = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buf in abl {
                    memset(buf.mData, 0, Int(buf.mDataByteSize))
                }
                return noErr
            }
            e.attach(src)
            e.connect(src, to: e.mainMixerNode, fromBus: 0, toBus: 0, format: format)
            e.mainMixerNode.outputVolume = 0
            do {
                try e.start()
                self.engine = e
                DispatchQueue.main.async { self.running = true }
            } catch {
                NSLog("echo: audio engine failed: \(error)")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.engine?.stop()
            self.engine = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            DispatchQueue.main.async { self.running = false }
        }
    }
}
