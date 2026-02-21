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
        let urlString = "\(Config.signalURL)?call_id=\(callId)&role=caller"
        print("[SignalingClient] connecting to: \(urlString)")
        guard let url = URL(string: urlString) else {
            print("[SignalingClient] invalid URL")
            return
        }
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        receive()
    }

    private func receive() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                print("[SignalingClient] received message")
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self?.delegate?.signalingClient(self!, didReceive: json)
                }
                self?.receive()  // Continue listening
            case .failure(let error):
                print("[SignalingClient] receive error: \(error)")
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
