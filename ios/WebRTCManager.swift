import WebRTC

protocol WebRTCManagerDelegate: AnyObject {
    func webRTCManager(_ manager: WebRTCManager, didGenerateCandidate candidate: RTCIceCandidate)
    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState)
    func webRTCManager(_ manager: WebRTCManager, didProduceSDP sdp: [String: Any])
}

class WebRTCManager: NSObject {
    weak var delegate: WebRTCManagerDelegate?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private var peerConnection: RTCPeerConnection!
    private var capturer: RTCCameraVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?

    init(delegate: WebRTCManagerDelegate) {
        self.delegate = delegate
        super.init()
        setupPeerConnection()
        setupLocalMedia()
    }

    private func setupPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"]),
        ]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        peerConnection = WebRTCManager.factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        )
    }

    private func setupLocalMedia() {
        // Audio
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = WebRTCManager.factory.audioSource(with: audioConstraints)
        let audioTrack = WebRTCManager.factory.audioTrack(with: audioSource, trackId: "audio0")
        peerConnection.add(audioTrack, streamIds: ["stream0"])

        // Video
        let videoSource = WebRTCManager.factory.videoSource()
        localVideoTrack = WebRTCManager.factory.videoTrack(with: videoSource, trackId: "video0")
        peerConnection.add(localVideoTrack!, streamIds: ["stream0"])

        capturer = RTCCameraVideoCapturer(delegate: videoSource)
        startCameraCapture(retryCount: 0)
    }

    private func startCameraCapture(retryCount: Int) {
        guard let frontCamera = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front }) else {
            print("[WebRTC] ERROR: No front camera found")
            return
        }
        // Pick a format close to 1280x720 — full 4032x3024 overwhelms the WebRTC encoder
        let formats = RTCCameraVideoCapturer.supportedFormats(for: frontCamera)
        guard let format = formats.min(by: {
            let d0 = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let d1 = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return abs(Int(d0.width) - 1280) < abs(Int(d1.width) - 1280)
        }) else {
            print("[WebRTC] ERROR: No supported camera format")
            return
        }
        guard let fps = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else {
            print("[WebRTC] ERROR: No FPS range")
            return
        }

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        print("[WebRTC] Starting camera: \(dims.width)x\(dims.height) @ \(Int(fps.maxFrameRate))fps (attempt \(retryCount + 1))")

        capturer?.startCapture(with: frontCamera, format: format, fps: Int(fps.maxFrameRate)) { [weak self] error in
            if let error {
                print("[WebRTC] Camera start FAILED: \(error)")
                if retryCount < 3 {
                    print("[WebRTC] Retrying camera start in 1s...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.startCameraCapture(retryCount: retryCount + 1)
                    }
                } else {
                    print("[WebRTC] Camera failed after \(retryCount + 1) attempts")
                }
            } else {
                print("[WebRTC] Camera started successfully")
            }
        }
    }

    func createOffer(callId: String, completion: @escaping ([String: Any]) -> Void) {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
            ],
            optionalConstraints: nil
        )
        peerConnection.offer(for: constraints) { [weak self] sdp, error in
            guard let sdp else { return }
            self?.peerConnection.setLocalDescription(sdp) { _ in
                completion(["type": "offer", "call_id": callId, "sdp": sdp.sdp])
            }
        }
    }

    func handleRemoteSDP(_ dict: [String: Any]) {
        guard let typeStr = dict["type"] as? String,
              let sdpStr = dict["sdp"] as? String else { return }
        let type: RTCSdpType = typeStr == "offer" ? .offer : .answer
        let sdp = RTCSessionDescription(type: type, sdp: sdpStr)
        peerConnection.setRemoteDescription(sdp) { _ in }
    }

    func handleRemoteCandidate(_ dict: [String: Any]) {
        guard let sdp = dict["candidate"] as? String,
              let sdpMid = dict["sdpMid"] as? String,
              let sdpMLineIndex = dict["sdpMLineIndex"] as? Int32 else { return }
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        peerConnection.add(candidate) { _ in }
    }

    func renderLocalVideo(to renderer: RTCVideoRenderer) {
        localVideoTrack?.add(renderer)
    }

    func disconnect() {
        capturer?.stopCapture()
        peerConnection.close()
    }
}

extension WebRTCManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        delegate?.webRTCManager(self, didGenerateCandidate: candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        delegate?.webRTCManager(self, didChangeConnectionState: newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
