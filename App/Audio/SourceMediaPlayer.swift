import AVFoundation

/// Plays the original audio track of a selected audio or video file while its
/// realtime transcription stream publishes subtitles.
@MainActor
final class SourceMediaPlayer {
    private var player: AVPlayer?

    func play(_ url: URL) {
        stop()
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
