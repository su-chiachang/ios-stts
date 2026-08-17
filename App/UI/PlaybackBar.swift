import AVKit
import SwiftUI

/// Embeds AVKit's native transport controls while keeping the AVPlayer
/// available to the transcript timeline observer.
struct PlaybackBar: View {
    @ObservedObject var playback: AudioPlaybackController
    var height: CGFloat? = nil

    var body: some View {
        Group {
            if let player = playback.avPlayer {
                NativePlaybackView(player: player)
                    .frame(height: height ?? (playback.hasVideo ? 240 : 76))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let errorMessage = playback.errorMessage {
                Text("Playback unavailable: \(errorMessage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#if os(iOS)
private struct NativePlaybackView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let viewController = AVPlayerViewController()
        viewController.player = player
        viewController.showsPlaybackControls = true
        return viewController
    }

    func updateUIViewController(_ viewController: AVPlayerViewController, context: Context) {
        if viewController.player !== player {
            viewController.player = player
        }
    }

    static func dismantleUIViewController(
        _ viewController: AVPlayerViewController,
        coordinator: ()
    ) {
        viewController.player = nil
    }
}
#elseif os(macOS)
private struct NativePlaybackView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsTimecodes = true
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
#endif
