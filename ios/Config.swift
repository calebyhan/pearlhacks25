import CoreLocation

enum Config {
    static let presageApiKey = Secrets.presageApiKey
    static let serverHost    = "wss://visual911.mooo.com"

    // WebSocket endpoints
    static let signalURL  = "\(serverHost)/ws/signal"
    static let audioURL   = "\(serverHost)/ws/audio"
    static let vitalsURL  = "\(serverHost)/ws/vitals"
    static let alertsURL  = "\(serverHost)/ws/alerts"

    // Set to a coordinate to override GPS in demos (nil = use real GPS)
    static let demoLocationOverride: CLLocationCoordinate2D? = nil
    // Example: CLLocationCoordinate2D(latitude: 35.9132, longitude: -79.0558)
}
