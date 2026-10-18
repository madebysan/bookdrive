import SwiftUI
import AVFoundation

/// UIViewRepresentable that wraps a UIView with an AVPlayerLayer for video rendering.
/// AVPlayerLayer automatically renders video frames from the AVPlayer using .resizeAspect (letterbox).
struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
    }

    /// Custom UIView that uses AVPlayerLayer as its backing layer
    class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        var player: AVPlayer? {
            get { playerLayer.player }
            set {
                playerLayer.player = newValue
                playerLayer.videoGravity = .resizeAspect
            }
        }
    }
}
