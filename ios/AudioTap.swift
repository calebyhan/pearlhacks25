import AVFoundation

class AudioTap {
    private let callId: String
    private var engine = AVAudioEngine()
    private var webSocket: URLSessionWebSocketTask?
    private var frameTimer: Timer?
    private var session: URLSession
    weak var webRTCManager: WebRTCManager?

    init(callId: String) {
        self.callId = callId
        self.session = URLSession(configuration: .default)
    }

    func start() {
        setupAudioSession()
        connectWebSocket()
        setupEngine()
        scheduleFrames()
    }

    private func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetooth])
        try? audioSession.setActive(true)

        // Reinstall tap if route changes (e.g. headphones plugged in)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    private func connectWebSocket() {
        guard let url = URL(string: "\(Config.audioURL)?call_id=\(callId)") else { return }
        var request = URLRequest(url: url)
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()
    }

    private func setupEngine() {
        let inputNode = engine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer: buffer, to: format) else { return }
            let data = Data(buffer: converted.int16ChannelData![0].withMemoryRebound(to: UInt8.self, capacity: Int(converted.frameLength) * 2) {
                UnsafeBufferPointer(start: $0, count: Int(converted.frameLength) * 2)
            })
            self.webSocket?.send(.data(data)) { _ in }
        }

        try? engine.start()
    }

    private func convert(buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let frameCount = AVAudioFrameCount(format.sampleRate / buffer.format.sampleRate * Double(buffer.frameLength))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    private func scheduleFrames() {
        // Capture a JPEG snapshot every 2 seconds for Gemini scene awareness
        frameTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.captureAndSendFrame()
        }
    }

    private func captureAndSendFrame() {
        guard let jpeg = webRTCManager?.captureJPEG() else { return }
        let payload: [String: Any] = ["type": "frame", "data": jpeg.base64EncodedString()]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: json, encoding: .utf8) else { return }
        webSocket?.send(.string(jsonStr)) { _ in }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        engine.inputNode.removeTap(onBus: 0)
        setupEngine()
    }

    func stop() {
        frameTimer?.invalidate()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        webSocket?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
