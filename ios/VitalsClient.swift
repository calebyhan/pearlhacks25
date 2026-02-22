import Foundation

class VitalsClient {
    private let callId: String
    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)

    init(callId: String) {
        self.callId = callId
    }

    func connect() {
        let urlString = "\(Config.vitalsURL)?call_id=\(callId)"
        print("[VitalsClient] connecting to: \(urlString)")
        guard let url = URL(string: urlString) else {
            print("[VitalsClient] invalid URL")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()
    }

    func send(reading: VitalsReading) {
        // Send 0.5 for unstable readings instead of 0.0 so the dashboard
        // still displays the value (with a "weak signal" indicator).
        let payload: [String: Any] = [
            "type": "vitals",
            "call_id": callId,
            "hr": reading.hr,
            "hrConfidence": reading.hrStable ? 1.0 : 0.5,
            "breathing": reading.breathing,
            "breathingConfidence": reading.brStable ? 1.0 : 0.5,
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
