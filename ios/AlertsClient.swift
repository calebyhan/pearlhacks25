import Foundation

struct CommunityAlert: Identifiable {
    let id: String          // incident_id
    let latitude: Double
    let longitude: Double
    var reportCount: Int
    var severity: Double
    var alertedCount: Int
}

class AlertsClient {
    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var isConnected = false
    private var shouldReconnect = true
    var onAlertsUpdated: (([CommunityAlert]) -> Void)?

    /// Current active alerts, keyed by incident_id
    private var alerts: [String: CommunityAlert] = [:]

    func connect() {
        shouldReconnect = true
        openSocket()
    }

    func disconnect() {
        shouldReconnect = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
    }

    private func openSocket() {
        guard shouldReconnect else { return }
        let urlString = "\(Config.alertsURL)"
        guard let url = URL(string: urlString) else {
            print("[AlertsClient] invalid URL: \(urlString)")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()
        isConnected = true
        print("[AlertsClient] connected to \(urlString)")
        listen()
    }

    private func listen() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                default:
                    break
                }
                self.listen() // continue listening
            case .failure(let error):
                print("[AlertsClient] receive error: \(error)")
                self.isConnected = false
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "community_alert":
            guard let incidentId = json["incident_id"] as? String,
                  let location = json["location"] as? [String: Any],
                  let lat = location["lat"] as? Double,
                  let lng = location["lng"] as? Double else { return }
            let alert = CommunityAlert(
                id: incidentId,
                latitude: lat,
                longitude: lng,
                reportCount: json["report_count"] as? Int ?? 1,
                severity: json["severity"] as? Double ?? 0,
                alertedCount: json["alerted_count"] as? Int ?? 0
            )
            alerts[incidentId] = alert
            notifyUpdate()

        case "active_incidents":
            guard let incidents = json["incidents"] as? [[String: Any]] else { return }
            alerts.removeAll()
            for inc in incidents {
                guard let incId = inc["incident_id"] as? String,
                      let location = inc["location"] as? [String: Any],
                      let lat = location["lat"] as? Double,
                      let lng = location["lng"] as? Double else { continue }
                alerts[incId] = CommunityAlert(
                    id: incId,
                    latitude: lat,
                    longitude: lng,
                    reportCount: inc["report_count"] as? Int ?? 1,
                    severity: inc["severity"] as? Double ?? 0,
                    alertedCount: inc["alerted_count"] as? Int ?? 0
                )
            }
            notifyUpdate()

        case "incident_closed":
            guard let incidentId = json["incident_id"] as? String else { return }
            alerts.removeValue(forKey: incidentId)
            notifyUpdate()

        default:
            break
        }
    }

    private func notifyUpdate() {
        let current = Array(alerts.values)
        DispatchQueue.main.async { [weak self] in
            self?.onAlertsUpdated?(current)
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        print("[AlertsClient] reconnecting in 3s...")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.openSocket()
        }
    }
}
