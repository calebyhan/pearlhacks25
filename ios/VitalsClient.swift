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
