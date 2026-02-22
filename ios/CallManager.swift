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
    /// Real-time scan feedback from Presage (lighting, face position, etc.)
    @Published var scanFeedback: ScanFeedback?
    /// Community alerts received while idle
    @Published var nearbyAlerts: [CommunityAlert] = []

    private var callId: String?
    private let presage = PresageManager()
    private var webrtc: WebRTCManager?
    private var audioTap: AudioTap?
    private var signalingClient: SignalingClient?
    private var vitalsClient: VitalsClient?
    private let alertsClient = AlertsClient()
    private var locationManager = CLLocationManager()
    private var cancellables = Set<AnyCancellable>()
    private var scanTimeoutWork: DispatchWorkItem?
    private var scanStartTime: Date?
    /// Last time an error status was observed — used to debounce flickering statuses.
    private var lastErrorTime: Date?
    /// Minimum seconds before we accept a reading (gives feedback time to show).
    private let minScanDuration: TimeInterval = 5.0
    /// Status must be error-free for this long before auto-finishing.
    private let errorCooldown: TimeInterval = 2.0
    /// Fires when the scan finishes (vitals received or timeout). UI can observe this.
    @Published var scanComplete: Bool = false

    init() {
        alertsClient.onAlertsUpdated = { [weak self] alerts in
            self?.nearbyAlerts = alerts
        }
        alertsClient.connect()
    }

    func onSOSPressed() {
        guard state == .idle else { return }
        callId = UUID().uuidString
        scanComplete = false
        transition(to: .scanning)
        startPresageScan()
    }

    private func startPresageScan() {
        scanStartTime = Date()
        lastErrorTime = nil
        presage.startMeasuring()

        // Forward SDK status-code errors (face not found, too dark, etc.)
        presage.$scanFeedback
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sdkFeedback in
                guard let self else { return }
                // SDK errors always take priority over vitals-based feedback
                if let sdkFeedback, sdkFeedback.isError {
                    self.scanFeedback = sdkFeedback
                    self.lastErrorTime = Date()
                }
                // When SDK has no feedback (status .ok or .processingNotStarted),
                // let vitals-based feedback drive the UI (see latestReading sink below)
            }
            .store(in: &cancellables)

        // Collect vitals readings continuously and generate quality-based feedback
        presage.$latestReading
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reading in
                guard let self else { return }
                self.lastVitals = reading

                // Only update feedback if the SDK isn't actively reporting an error
                if self.presage.scanFeedback?.isError != true {
                    if reading.hrStable && reading.brStable {
                        self.scanFeedback = .signalStable
                    } else {
                        self.scanFeedback = .signalWeak
                        self.lastErrorTime = Date()
                    }
                }
                self.tryFinishScan()
            }
            .store(in: &cancellables)

        // Poll every second to catch the cooldown window
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.state != .scanning { t.invalidate(); return }
            self.tryFinishScan()
        }

        // Hard timeout: finish regardless of quality after 15 seconds
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishScan()
        }
        scanTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    /// Attempt to finish the scan. Only succeeds when ALL conditions are met:
    /// 1. Minimum scan duration has passed
    /// 2. We have vitals data with stable signals
    /// 3. No active error condition (SDK status or weak signal)
    /// 4. No error seen in the last `errorCooldown` seconds (debounce flickering)
    private func tryFinishScan() {
        guard state == .scanning else { return }
        guard let vitals = lastVitals else { return }
        guard let start = scanStartTime,
              Date().timeIntervalSince(start) >= minScanDuration else { return }
        // Require stable vitals signals (not just SDK .ok)
        guard vitals.hrStable && vitals.brStable else { return }
        // Don't accept readings while Presage reports an error
        guard scanFeedback?.isError != true else { return }
        // Require sustained good status — no error in the last N seconds
        if let lastErr = lastErrorTime,
           Date().timeIntervalSince(lastErr) < errorCooldown { return }
        finishScan()
    }

    /// Unconditionally ends the scan (called by tryFinishScan or hard timeout).
    private func finishScan() {
        // Prevent double execution (vitals + timeout race)
        guard state == .scanning else { return }

        scanTimeoutWork?.cancel()
        scanTimeoutWork = nil
        scanStartTime = nil
        lastErrorTime = nil
        presage.stopMeasuring()

        DispatchQueue.main.async {
            self.scanFeedback = nil
            self.scanComplete = true
            if self.lastVitals == nil {
                self.lastVitals = self.presage.latestReading
            }
            self.initiateCall()
        }
    }

    /// Restarts the Presage scan (e.g. user wants to re-try after poor conditions).
    func retryScan() {
        guard state == .scanning else { return }
        scanTimeoutWork?.cancel()
        scanTimeoutWork = nil
        scanStartTime = nil
        lastErrorTime = nil
        presage.stopMeasuring()
        cancellables.removeAll()
        scanComplete = false
        lastVitals = nil
        scanFeedback = nil
        startPresageScan()
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

        // Stop listening for community alerts during a call
        alertsClient.disconnect()

        signalingClient = SignalingClient(callId: callId, delegate: self)
        vitalsClient = VitalsClient(callId: callId)
        audioTap = AudioTap(callId: callId)

        print("[CallManager] connecting signaling...")
        signalingClient?.connect()
        print("[CallManager] connecting vitals...")
        vitalsClient?.connect()
        print("[CallManager] starting audio tap...")
        audioTap?.start()

        // Register the call on the server FIRST so vitals aren't dropped
        signalingClient?.send([
            "type": "call_initiated",
            "call_id": callId,
            "location": locationDict
        ])

        // Small delay to let the server process call_initiated before vitals arrive
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let vitals = self.lastVitals else {
                print("[CallManager] no vitals from Presage scan (too dark or no confident reading)")
                return
            }
            print("[CallManager] sending cached vitals: HR=\(vitals.hr) BR=\(vitals.breathing)")
            self.vitalsClient?.send(reading: vitals)
        }
    }

    func onDispatcherReady() {
        transition(to: .connecting)
        let webrtc = WebRTCManager(delegate: self)
        self.webrtc = webrtc
        audioTap?.webRTCManager = webrtc
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
        // Ensure we're on the main thread to prevent race conditions
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.endCall(reason: reason)
            }
            return
        }
        // Guard against re-entrant calls (ICE failed + signaling call_ended race)
        guard state != .cleanup && state != .idle else { return }
        state = .cleanup

        // Capture and nil-out references so a second call is a safe no-op
        let sig = signalingClient;  signalingClient = nil
        let vit = vitalsClient;     vitalsClient = nil
        let tap = audioTap;         audioTap = nil
        let rtc = webrtc;           webrtc = nil

        sig?.send(["type": "call_ended", "call_id": callId ?? ""])
        sig?.disconnect()
        vit?.disconnect()
        tap?.stop()
        rtc?.disconnect()
        presage.stopMeasuring()
        callId = nil
        scanStartTime = nil
        lastErrorTime = nil
        cancellables.removeAll()
        lastVitals = nil
        lastLocation = nil
        isMuted = false
        scanComplete = false
        scanFeedback = nil
        nearbyAlerts = []
        state = .idle

        // Re-subscribe to community alerts
        alertsClient.connect()
    }

    private func currentLocation() -> CLLocationCoordinate2D? {
        if let demo = Config.demoLocationOverride { return demo }
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
