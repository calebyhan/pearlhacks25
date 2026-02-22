import SmartSpectraSwiftSDK
import Combine
import Foundation

struct VitalsReading {
    let hr: Double
    let hrStable: Bool
    let breathing: Double
    let brStable: Bool
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
        sdk.setImageOutputEnabled(true) // enables vitalsProcessor.imageOutput for camera preview
    }

    func startMeasuring() {
        processor.startProcessing()
        processor.startRecording()

        sdk.$metricsBuffer
            .compactMap { $0 }
            .sink { [weak self] buffer in
                guard
                    let hrVal = buffer.pulse.rate.last,
                    let breathVal = buffer.breathing.rate.last
                else { return }

                let reading = VitalsReading(
                    hr: Double(hrVal.value),
                    hrStable: hrVal.stable,
                    breathing: Double(breathVal.value),
                    brStable: breathVal.stable,
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
