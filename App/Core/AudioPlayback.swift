@preconcurrency import AVFoundation
import Combine
import Foundation

/// Owns the AVPlayer used by the transcription result's native playback view
/// and publishes its timeline for transcript highlighting.
@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var hasMedia = false
    @Published private(set) var hasVideo = false
    @Published private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var timeJumpObserver: NSObjectProtocol?
    private var durationTask: Task<Void, Never>?
    private var scopedURL: URL?
    private var isAccessingScopedResource = false

    var avPlayer: AVPlayer? { player }

    func load(url: URL) {
        unload()

        let isAccessingScopedResource = url.startAccessingSecurityScopedResource()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)

        self.player = player
        scopedURL = url
        self.isAccessingScopedResource = isAccessingScopedResource
        hasMedia = true
        hasVideo = false
        errorMessage = nil

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.updateTime(time)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded()
            }
        }

        timeJumpObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCurrentTime()
            }
        }

        durationTask = Task { @MainActor [weak self, asset] in
            do {
                let time = try await asset.load(.duration)
                try Task.checkCancellation()
                let seconds = time.seconds
                if seconds.isFinite, seconds > 0 {
                    self?.duration = seconds
                }
            } catch is CancellationError {
                // Loading a new file cancels the previous asset request.
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }

            do {
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                try Task.checkCancellation()
                self?.hasVideo = !videoTracks.isEmpty
            } catch is CancellationError {
                // Loading a new file cancels the previous asset request.
            } catch {
                self?.hasVideo = false
            }
        }
    }

    func unload() {
        durationTask?.cancel()
        durationTask = nil

        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        if let timeJumpObserver {
            NotificationCenter.default.removeObserver(timeJumpObserver)
        }
        timeJumpObserver = nil

        player?.pause()
        player = nil

        if isAccessingScopedResource, let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        scopedURL = nil
        isAccessingScopedResource = false

        currentTime = 0
        duration = 0
        hasMedia = false
        hasVideo = false
        errorMessage = nil
    }

    private func updateTime(_ time: CMTime) {
        guard hasMedia, time.isValid else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }

        currentTime = duration > 0
            ? min(max(0, seconds), duration)
            : max(0, seconds)
    }

    private func refreshCurrentTime() {
        guard let player else { return }
        updateTime(player.currentTime())
    }

    private func handlePlaybackEnded() {
        guard hasMedia else { return }
        currentTime = duration
    }
}
