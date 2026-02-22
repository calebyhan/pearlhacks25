enum Config {
    static let presageApiKey = Secrets.presageApiKey
    static let serverHost    = "wss://visual911.mooo.com"

    // WebSocket endpoints
    static let signalURL  = "\(serverHost)/ws/signal"
    static let audioURL   = "\(serverHost)/ws/audio"
    static let vitalsURL  = "\(serverHost)/ws/vitals"
}
