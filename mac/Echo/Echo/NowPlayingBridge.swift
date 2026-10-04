import AppKit
import MediaPlayer

/// Publishes the iPhone's Now Playing to macOS (`MPNowPlayingInfoCenter`)
/// and routes system media controls (`MPRemoteCommandCenter`) back to it.
///
/// Effect: Mac keyboard media keys, Control Center, and headphones paired
/// to the Mac control the iPhone through the relay.
final class NowPlayingBridge {
    /// e.g. `["action": "pause"]` — the owner forwards these to the relay.
    var onCommand: (([String: Any]) -> Void)?

    private let center = MPNowPlayingInfoCenter.default()
    private let remote = MPRemoteCommandCenter.shared()

    init() {
        remote.playCommand.addTarget { [weak self] _ in
            self?.onCommand?(["action": "play"])
            return .success
        }
        remote.pauseCommand.addTarget { [weak self] _ in
            self?.onCommand?(["action": "pause"])
            return .success
        }
        remote.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onCommand?(["action": "toggle"])
            return .success
        }
        remote.nextTrackCommand.addTarget { [weak self] _ in
            self?.onCommand?(["action": "next"])
            return .success
        }
        remote.previousTrackCommand.addTarget { [weak self] _ in
            self?.onCommand?(["action": "previous"])
            return .success
        }
        remote.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let pos = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime,
                  pos.isFinite, pos >= 0 else { return .commandFailed }
            self?.onCommand?(["action": "seek", "position": pos])
            return .success
        }
    }

    /// Push the latest relay snapshot into the system slot.
    /// `nil` clears our claim so Music.app owns Now Playing again.
    func update(track: BarTrack?) {
        let hasTrack = track != nil
        for cmd in [remote.playCommand, remote.pauseCommand,
                    remote.togglePlayPauseCommand, remote.nextTrackCommand,
                    remote.previousTrackCommand, remote.changePlaybackPositionCommand] as [MPRemoteCommand] {
            cmd.isEnabled = hasTrack
        }
        guard let t = track else {
            center.nowPlayingInfo = [:]
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: t.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: t.position,
            MPNowPlayingInfoPropertyPlaybackRate: t.isPlaying ? 1.0 : 0.0,
            // Claim the audio slot explicitly: system Now Playing readers
            // key off this property.
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let art = t.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        center.nowPlayingInfo = info
    }
}
