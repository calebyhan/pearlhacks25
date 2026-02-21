import SmartSpectraSwiftSDK
import Combine
import Foundation

struct VitalsReading {
    let hr: Double
    let hrConfidence: Double
    let breathing: Double
    let breathingConfidence: Double
    let timestamp: Date
}

class PresageManager: ObservableObject {
    @Published var latestReading: VitalsReading?
    private let sdk = SmartSpectraSwiftSDK.shared
    private let processor = SmartSpectraVitalsProcessor.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        sdk.setApiKey(Config.presageApiKey)
        sdk.setSmartSpectraMode(.continuous)
        sdk.setCameraPosition(.front)
        sdk.setImageOutputEnabled(false) // headless — no preview needed
    }

    func startMeasuring() {
        processor.startProcessing()
        processor.startRecording()

        // Observe MetricsBuffer updates from the SDK singleton
        sdk.$metricsBuffer
            .compactMap { $0 }
            .sink { [weak self] buffer in
                guard
                    let hrVal = buffer.pulse.rate.last,
                    let breathVal = buffer.breathing.rate.last
                else { return }

                let reading = VitalsReading(
                    hr: Double(hrVal.value),
                    hrConfidence: Double(hrVal.confidence),
                    breathing: Double(breathVal.value),
                    breathingConfidence: Double(breathVal.confidence),
                    timestamp: Date()
                )
                DispatchQueue.main.async {
                    self?.latestReading = reading
                }
            }
            .store(in: &cancellables)
    }

    func stopMeasuring() {
        processor.stopRecording()
        processor.stopProcessing()
        cancellables.removeAll()
    }
}
