enum Config {
    static let presageApiKey = Secrets.presageApiKey
    static let serverHost    = "wss://postlike-clarissa-muddiest.ngrok-free.dev"

    // WebSocket endpoints
    static let signalURL  = "\(serverHost)/ws/signal"
    static let audioURL   = "\(serverHost)/ws/audio"
    static let vitalsURL  = "\(serverHost)/ws/vitals"
}
