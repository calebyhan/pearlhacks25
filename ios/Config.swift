enum Config {
    static let presageApiKey = "TXPMACagDJaJbZHKrSjps5HmESap5JsL8RGiPnsS"
    // Gemini key lives server-side only — never set here
    static let serverHost    = "ws://152.23.73.108:8080"

    // WebSocket endpoints
    static let signalURL  = "\(serverHost)/ws/signal"
    static let audioURL   = "\(serverHost)/ws/audio"
    static let vitalsURL  = "\(serverHost)/ws/vitals"
}
