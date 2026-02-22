import SwiftUI
import Combine
import CoreLocation
import WebRTC

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
    @Published var lastLocation: CLLocationCoordinate2D?
    @Published var isMuted: Bool = false

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

        // Capture first reading (stable or not — stability shown in UI)
        presage.$latestReading
            .compactMap { $0 }
            .first()
            .sink { [weak self] reading in
                self?.lastVitals = reading
            }
            .store(in: &cancellables)

        // Stop after 15 seconds regardless
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.presage.stopMeasuring()
            // One extra main-queue cycle lets any pending latestReading dispatch land
            DispatchQueue.main.async {
                if self.lastVitals == nil {
                    self.lastVitals = self.presage.latestReading
                }
                self.initiateCall()
            }
        }
    }

    private func initiateCall() {
        guard let callId else {
            print("[CallManager] initiateCall: callId is nil, aborting")
            return
        }
        print("[CallManager] initiateCall: starting with callId=\(callId)")
        let location = currentLocation()
        let locationDict: [String: Any] = location.map {
            ["lat": $0.latitude, "lng": $0.longitude]
        } ?? [:]

        lastLocation = location
        transition(to: .initiating)

        signalingClient = SignalingClient(callId: callId, delegate: self)
        vitalsClient = VitalsClient(callId: callId)
        audioTap = AudioTap(callId: callId)

        print("[CallManager] connecting signaling...")
        signalingClient?.connect()
        print("[CallManager] connecting vitals...")
        vitalsClient?.connect()
        print("[CallManager] starting audio tap...")
        audioTap?.start()

        // Send cached vitals from the Presage scan immediately
        if let vitals = lastVitals {
            print("[CallManager] sending cached vitals: HR=\(vitals.hr) BR=\(vitals.breathing)")
            vitalsClient?.send(reading: vitals)
        } else {
            print("[CallManager] no vitals from Presage scan (too dark or no confident reading)")
        }

        signalingClient?.send([
            "type": "call_initiated",
            "call_id": callId,
            "location": locationDict
        ])
    }

    func onDispatcherReady() {
        transition(to: .connecting)
        let webrtc = WebRTCManager(delegate: self)
        self.webrtc = webrtc
        webrtc.createOffer(callId: callId ?? "") { [weak self] sdp in
            self?.signalingClient?.send(sdp)
        }
    }

    func toggleMute() {
        isMuted.toggle()
        webrtc?.setAudioMuted(isMuted)
    }

    func renderLocalVideo(to renderer: RTCVideoRenderer) {
        webrtc?.renderLocalVideo(to: renderer)
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
        print("[WebRTC] ICE state: \(state.rawValue)")
        DispatchQueue.main.async { [weak self] in
            switch state {
            case .connected, .completed:
                self?.transition(to: .active)
                // Resend cached vitals — dispatcher_ws is now guaranteed set
                if let vitals = self?.lastVitals {
                    self?.vitalsClient?.send(reading: vitals)
                }
            case .failed:
                self?.endCall(reason: "connection_failed")
            case .disconnected:
                // Transient state — ICE may recover. Don't tear down.
                print("[WebRTC] ICE disconnected (transient, not ending call)")
            default:
                break
            }
        }
    }

    func webRTCManager(_ manager: WebRTCManager, didProduceSDP sdp: [String: Any]) {
        signalingClient?.send(sdp)
    }
}
