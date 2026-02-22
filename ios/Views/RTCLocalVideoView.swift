import SwiftUI
import WebRTC

/// UIViewRepresentable that renders the local WebRTC camera feed using Metal.
struct RTCLocalVideoView: UIViewRepresentable {
    let manager: CallManager

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        view.backgroundColor = UIColor(white: 0.85, alpha: 1)
        view.transform = CGAffineTransform(scaleX: -1, y: 1)
        manager.renderLocalVideo(to: view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}
