import SmartSpectraSwiftSDK
import Combine

struct VitalsReading {
    let hr: Double
    let hrConfidence: Double
    let breathing: Double
    let breathingConfidence: Double
    let timestamp: Date
}

class PresageManager: ObservableObject {
    @Published var latestReading: VitalsReading?
    private var sdk = SmartSpectraSwiftSDK.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        sdk.setApiKey(Config.presageApiKey)
    }

    func startMeasuring() {
        sdk.startMeasuring()

        // Observe MetricsBuffer updates
        sdk.$metricsBuffer
            .compactMap { $0 }
            .sink { [weak self] buffer in
                guard
                    let hrVal = buffer.pulse.rate.last,
                    let breathVal = buffer.breathing.rate.last
                else { return }

                let reading = VitalsReading(
                    hr: hrVal.value,
                    hrConfidence: hrVal.confidence,
                    breathing: breathVal.value,
                    breathingConfidence: breathVal.confidence,
                    timestamp: Date()
                )
                DispatchQueue.main.async {
                    self?.latestReading = reading
                }
            }
            .store(in: &cancellables)
    }

    func stopMeasuring() {
        sdk.stopMeasuring()
    }
}
