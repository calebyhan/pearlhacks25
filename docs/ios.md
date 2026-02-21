# iOS App

## Overview

The iOS app is a Swift/SwiftUI application that manages the full call lifecycle. It coordinates three hardware subsystems (Presage camera, WebRTC camera, AVAudioEngine microphone), three WebSocket connections to the Vultr server, and one P2P WebRTC connection to the dispatcher browser.

Physical device required. Simulator has no camera.

---

## Dependencies

Add via Swift Package Manager:

| Package | URL | Purpose |
|---|---|---|
| SmartSpectra iOS SDK | `https://github.com/Presage-Security/SmartSpectra-iOS-SDK` | Contactless vitals |
| WebRTC | `https://github.com/stasel/WebRTC.git` branch: `latest` | P2P video/audio |

---

## Project Structure

```
ios/
├── Config.swift              # API keys, server URLs — never commit real values
├── CallManager.swift         # Central state machine, owns all subsystems
├── PresageManager.swift      # Presage SDK wrapper
├── WebRTCManager.swift       # RTCPeerConnection, capturer, data handling
├── AudioTap.swift            # AVAudioEngine tap → /ws/audio WebSocket
├── SignalingClient.swift     # /ws/signal WebSocket
├── VitalsClient.swift        # /ws/vitals WebSocket
└── Views/
    ├── IdleView.swift        # SOS button, "monitoring ready" state
    ├── ScanningView.swift    # Presage vitals scan in progress
    └── ActiveCallView.swift  # Connected call, vitals readout, end button
```

---

## Config.swift

```swift
enum Config {
    static let presageApiKey = "YOUR_PRESAGE_KEY"
    static let geminiApiKey  = ""  // Never set here — server-side only
    static let serverHost    = "wss://yourdomain.com"

    // WebSocket endpoints
    static let signalURL  = "\(serverHost)/ws/signal"
    static let audioURL   = "\(serverHost)/ws/audio"
    static let vitalsURL  = "\(serverHost)/ws/vitals"
}
```

---

## CallManager.swift

Central coordinator. Owns the state machine and holds references to all subsystems.

```swift
import SwiftUI
import Combine

enum CallState {
    case idle
    case scanning          // Presage running
    case initiating        // WebSockets open, waiting for dispatcher
    case connecting        // WebRTC handshake in progress
    case active            // All systems live
    case cleanup
}

class CallManager: ObservableObject {
    @Published var state: CallState = .idle
    @Published var lastVitals: VitalsReading?

    private var callId: String?
    private let presage = PresageManager()
    private var webrtc: WebRTCManager?
    private var audioTap: AudioTap?
    private var signalingClient: SignalingClient?
    private var vitalsClient: VitalsClient?
    private var locationManager = CLLocationManager()
    private var cancellables = Set<AnyCancellable>()

    func onSOSPressed() {
        guard state == .idle else { return }
        callId = UUID().uuidString
        transition(to: .scanning)
        startPresageScan()
    }

    private func startPresageScan() {
        presage.startMeasuring()

        // Listen for first confident reading
        presage.$latestReading
            .compactMap { $0 }
            .filter { $0.hrConfidence > 0.7 }
            .first()
            .sink { [weak self] reading in
                self?.lastVitals = reading
            }
            .store(in: &cancellables)

        // Stop after 15 seconds regardless
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.presage.stopMeasuring()
            self?.initiateCall()
        }
    }

    private func initiateCall() {
        guard let callId else { return }
        // Proceed even without location — send zeros so the server doesn't block.
        // The map pin will be missing but the call still works.
        let location = currentLocation()
        let locationDict: [String: Any] = location.map {
            ["lat": $0.latitude, "lng": $0.longitude]
        } ?? [:]

        transition(to: .initiating)

        signalingClient = SignalingClient(callId: callId, delegate: self)
        vitalsClient = VitalsClient(callId: callId)
        audioTap = AudioTap(callId: callId)

        signalingClient?.connect()
        vitalsClient?.connect()
        audioTap?.start()

        // Send cached vitals from the Presage scan immediately
        if let vitals = lastVitals {
            vitalsClient?.send(reading: vitals)
        }

        signalingClient?.send([
            "type": "call_initiated",
            "call_id": callId,
            "location": locationDict
        ])
    }

    func onDispatcherReady() {
        // Called by SignalingClient delegate when server sends dispatcher_ready
        transition(to: .connecting)
        let webrtc = WebRTCManager(delegate: self)
        self.webrtc = webrtc
        webrtc.createOffer { [weak self] sdp in
            self?.signalingClient?.send(sdp)
        }
    }

    func endCall(reason: String = "caller_ended") {
        transition(to: .cleanup)
        signalingClient?.send(["type": "call_ended", "call_id": callId ?? ""])
        signalingClient?.disconnect()
        vitalsClient?.disconnect()
        audioTap?.stop()
        webrtc?.disconnect()
        presage.stopMeasuring()
        callId = nil
        transition(to: .idle)
    }

    private func currentLocation() -> CLLocationCoordinate2D? {
        locationManager.requestWhenInUseAuthorization()
        let loc = locationManager.location
        guard let loc, loc.horizontalAccuracy >= 0 else { return nil }
        return loc.coordinate
    }

    private func transition(to newState: CallState) {
        DispatchQueue.main.async { self.state = newState }
    }
}

// MARK: — SignalingClientDelegate

extension CallManager: SignalingClientDelegate {
    func signalingClient(_ client: SignalingClient, didReceive message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "dispatcher_ready":
            onDispatcherReady()
        case "call_ended":
            endCall(reason: message["reason"] as? String ?? "remote_ended")
        case "offer", "answer":
            webrtc?.handleRemoteSDP(message)
        case "ice":
            webrtc?.handleRemoteCandidate(message)
        default:
            break
        }
    }
}

// MARK: — WebRTCManagerDelegate

extension CallManager: WebRTCManagerDelegate {
    func webRTCManager(_ manager: WebRTCManager, didGenerateCandidate candidate: RTCIceCandidate) {
        signalingClient?.send([
            "type": "ice",
            "call_id": callId ?? "",
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "",
            "sdpMLineIndex": candidate.sdpMLineIndex
        ])
    }

    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState) {
        switch state {
        case .connected, .completed:
            transition(to: .active)
        case .failed, .disconnected:
            endCall(reason: "connection_failed")
        default:
            break
        }
    }

    func webRTCManager(_ manager: WebRTCManager, didProduceSDP sdp: [String: Any]) {
        signalingClient?.send(sdp)
    }
}
```

---

## PresageManager.swift

Wraps `SmartSpectraSwiftSDK.shared`. Publishes readings for CallManager to observe.

```swift
import SmartSpectraSwiftSDK
import Combine

struct VitalsReading {
    let hr: Double
    let hrConfidence: Double
    let breathing: Double
    let breathingConfidence: Double
    let timestamp: Date
}

class PresageManager: ObservableObject {
    @Published var latestReading: VitalsReading?
    private var sdk = SmartSpectraSwiftSDK.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        sdk.setApiKey(Config.presageApiKey)
    }

    func startMeasuring() {
        sdk.startMeasuring()

        // Observe MetricsBuffer updates
        sdk.$metricsBuffer
            .compactMap { $0 }
            .sink { [weak self] buffer in
                guard
                    let hrVal = buffer.pulse.rate.last,
                    let breathVal = buffer.breathing.rate.last
                else { return }

                let reading = VitalsReading(
                    hr: hrVal.value,
                    hrConfidence: hrVal.confidence,
                    breathing: breathVal.value,
                    breathingConfidence: breathVal.confidence,
                    timestamp: Date()
                )
                DispatchQueue.main.async {
                    self?.latestReading = reading
                }
            }
            .store(in: &cancellables)
    }

    func stopMeasuring() {
        sdk.stopMeasuring()
    }
}
```

**Note:** Check the actual `MetricsBuffer` property names against the SDK source. The `pulse.rate` / `breathing.rate` path is based on the documented structure — verify against `SmartSpectra-iOS-SDK` repo before building.

---

## WebRTCManager.swift

Manages `RTCPeerConnection` and `RTCCameraVideoCapturer`. After Presage stops, this takes over the front camera.

```swift
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
            RTCIceServer(urlStrings: ["stun:yourdomain.com:3478"]),
            RTCIceServer(
                urlStrings: ["turn:yourdomain.com:3478"],
                username: generatedTURNUsername(),
                credential: generatedTURNCredential()
            )
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

        // Start front camera capture
        capturer = RTCCameraVideoCapturer(delegate: videoSource)
        guard let frontCamera = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front }),
              let format = RTCCameraVideoCapturer.supportedFormats(for: frontCamera)
                .sorted(by: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
                              CMVideoFormatDescriptionGetDimensions($1.formatDescription).width })
                .last,
              let fps = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
        else { return }

        capturer?.startCapture(with: frontCamera, format: format, fps: Int(fps.maxFrameRate))
    }

    func createOffer(completion: @escaping ([String: Any]) -> Void) {
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
                completion(["type": "offer", "sdp": sdp.sdp])
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
    // Implement remaining required stubs (didChange signaling state, etc.)
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
```

---

## AudioTap.swift

Runs parallel to WebRTC audio. Taps the microphone via AVAudioEngine and streams 16kHz mono PCM to `/ws/audio`. Also sends periodic JPEG frames for Gemini scene awareness.

```swift
import AVFoundation

class AudioTap {
    private let callId: String
    private var engine = AVAudioEngine()
    private var webSocket: URLSessionWebSocketTask?
    private var frameTimer: Timer?
    private var session: URLSession

    init(callId: String) {
        self.callId = callId
        self.session = URLSession(configuration: .default)
    }

    func start() {
        setupAudioSession()
        connectWebSocket()
        setupEngine()
        scheduleFrames()
    }

    private func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetooth])
        try? audioSession.setActive(true)

        // Reinstall tap if route changes (e.g. headphones plugged in)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    private func connectWebSocket() {
        guard let url = URL(string: "\(Config.audioURL)?call_id=\(callId)") else { return }
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
    }

    private func setupEngine() {
        let inputNode = engine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer: buffer, to: format) else { return }
            let data = Data(buffer: converted.int16ChannelData![0].withMemoryRebound(to: UInt8.self, capacity: Int(converted.frameLength) * 2) {
                UnsafeBufferPointer(start: $0, count: Int(converted.frameLength) * 2)
            })
            self.webSocket?.send(.data(data)) { _ in }
        }

        try? engine.start()
    }

    private func convert(buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let frameCount = AVAudioFrameCount(format.sampleRate / buffer.format.sampleRate * Double(buffer.frameLength))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    private func scheduleFrames() {
        // Capture a JPEG snapshot every 2 seconds for Gemini scene awareness
        frameTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.captureAndSendFrame()
        }
    }

    private func captureAndSendFrame() {
        // Capture snapshot from the current camera session
        // In practice: grab from a shared RTCVideoRenderer or AVCaptureVideoDataOutput tap
        // For hackathon: use a UIScreen snapshot of the local preview view
        // See ios.md notes on frame capture approach
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        engine.inputNode.removeTap(onBus: 0)
        setupEngine()
    }

    func stop() {
        frameTimer?.invalidate()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        webSocket?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
```

**Frame capture note:** The simplest hackathon approach for JPEG frames is to render the local WebRTC video track to an offscreen `RTCMTLVideoView` and take a UIGraphicsImageRenderer snapshot every 2 seconds. This is a bit hacky but works. A cleaner approach would be a custom `RTCVideoRenderer` that retains the last `CVPixelBuffer` and converts it to JPEG on demand.

---

## SignalingClient.swift

WebSocket wrapper for `/ws/signal`. Forwards raw JSON between iOS and the server (which in turn forwards to the dispatcher dashboard).

```swift
import Foundation

protocol SignalingClientDelegate: AnyObject {
    func signalingClient(_ client: SignalingClient, didReceive message: [String: Any])
}

class SignalingClient: NSObject {
    weak var delegate: SignalingClientDelegate?
    private let callId: String
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession

    init(callId: String, delegate: SignalingClientDelegate) {
        self.callId = callId
        self.delegate = delegate
        self.session = URLSession(configuration: .default)
    }

    func connect() {
        guard let url = URL(string: "\(Config.signalURL)?call_id=\(callId)&role=caller") else { return }
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        receive()
    }

    private func receive() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self?.delegate?.signalingClient(self!, didReceive: json)
                }
                self?.receive()  // Continue listening
            case .failure:
                break  // Handle reconnection if needed
            }
        }
    }

    func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(text)) { _ in }
    }

    func disconnect() {
        webSocket?.cancel()
    }
}
```

---

## VitalsClient.swift

Sends vitals JSON to `/ws/vitals` after the Presage scan completes. Called once at call start with the cached `lastVitals` reading, then periodically if new readings arrive (though Presage is stopped, so in practice just the one initial send).

```swift
import Foundation

class VitalsClient {
    private let callId: String
    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)

    init(callId: String) {
        self.callId = callId
    }

    func connect() {
        guard let url = URL(string: "\(Config.vitalsURL)?call_id=\(callId)") else { return }
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
    }

    func send(reading: VitalsReading) {
        let payload: [String: Any] = [
            "type": "vitals",
            "call_id": callId,
            "hr": reading.hr,
            "hrConfidence": reading.hrConfidence,
            "breathing": reading.breathing,
            "breathingConfidence": reading.breathingConfidence,
            "timestamp": reading.timestamp.timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(text)) { _ in }
    }

    func disconnect() {
        webSocket?.cancel()
    }
}
```

Call `vitalsClient?.send(reading: lastVitals)` from `CallManager.initiateCall()` after `vitalsClient?.connect()`.

---

## Info.plist Requirements

```xml
<key>NSCameraUsageDescription</key>
<string>Visual911 uses the camera to measure your vital signs and share video with emergency responders.</string>

<key>NSMicrophoneUsageDescription</key>
<string>Visual911 uses the microphone to share audio with emergency responders and AI triage.</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>Visual911 shares your location with emergency responders.</string>
```

---

## TURN Credential Generation (iOS)

coturn uses time-limited HMAC credentials. Generate on the client:

```swift
import CryptoKit

func generateTURNCredentials(secret: String) -> (username: String, credential: String) {
    let expiry = Int(Date().timeIntervalSince1970) + 3600  // 1 hour
    let username = "\(expiry):visual911user"
    let key = SymmetricKey(data: Data(secret.utf8))
    // SHA1 lives under CryptoKit.Insecure — HMAC<SHA1> does not compile
    let mac = Insecure.HMAC<Insecure.SHA1>.authenticationCode(for: Data(username.utf8), using: key)
    let credential = Data(mac).base64EncodedString()
    return (username, credential)
}
```

In practice for the hackathon, hardcode a valid credential pair generated once at build time. For production, the server would vend credentials via an API call before the call starts.

---

## Build Checklist

- [ ] Physical iOS device connected (not simulator)
- [ ] Presage API key set in `Config.swift`
- [ ] Server URL set in `Config.swift` (`wss://`, not `ws://`)
- [ ] Bundle identifier set in Signing & Capabilities
- [ ] Paid Apple developer account (required for WebRTC entitlements)
- [ ] `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSLocationWhenInUseUsageDescription` in Info.plist
- [ ] Both SPM packages resolved (SmartSpectra, stasel/WebRTC)
- [ ] `CallManager` declared as `SignalingClientDelegate` and `WebRTCManagerDelegate` (see extensions at bottom of `CallManager.swift`)
- [ ] TURN credentials use `Insecure.HMAC<Insecure.SHA1>` (not `HMAC<SHA1>`)
- [ ] `captureAndSendFrame()` implemented in `AudioTap.swift` before demo
- [ ] Test Presage alone first (confirm HR readings before integrating WebRTC)
- [ ] Test WebRTC alone second (confirm video reaches browser before adding audio tap)
- [ ] Test full pipeline last
