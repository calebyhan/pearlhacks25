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

/// User-friendly scan feedback derived from Presage SDK status codes.
struct ScanFeedback: Equatable {
    let icon: String
    let message: String
    let isError: Bool   // true = problem, false = informational / ok

    /// Maps a Presage StatusCode to a user-facing hint.
    /// Returns nil for statuses that don't need UI feedback.
    /// Note: `.ok` returns nil because the SDK's "ok" status is unreliable —
    /// it can report `.ok` while the C++ layer simultaneously logs "too dark".
    /// Positive feedback is driven by vitals stability instead (see CallManager).
    static func from(_ code: StatusCode) -> ScanFeedback? {
        switch code {
        case .ok:
            return nil  // Don't show green banner — SDK .ok is unreliable for quality
        case .imageTooDark:
            return ScanFeedback(icon: "sun.max.fill", message: "Too dark — move to a brighter area", isError: true)
        case .imageTooBright:
            return ScanFeedback(icon: "sun.min.fill", message: "Too bright — reduce direct light on your face", isError: true)
        case .noFacesFound:
            return ScanFeedback(icon: "face.dashed", message: "No face detected — center your face in the frame", isError: true)
        case .moreThanOneFaceFound:
            return ScanFeedback(icon: "person.2.fill", message: "Multiple faces — only one person should be in frame", isError: true)
        case .faceNotCentered:
            return ScanFeedback(icon: "viewfinder", message: "Center your face in the frame", isError: true)
        case .faceTooBigOrTooSmall:
            return ScanFeedback(icon: "arrow.up.left.and.arrow.down.right", message: "Adjust distance — move closer or further away", isError: true)
        case .chestTooFarOrNotEnoughShowing:
            return ScanFeedback(icon: "person.bust", message: "Show more of your upper body in the frame", isError: true)
        case .processingNotStarted:
            return nil
        default:
            return nil
        }
    }

    // Positive feedback driven by vitals quality (not SDK status)
    static let signalStable = ScanFeedback(icon: "checkmark.circle.fill", message: "Signal stable — measuring vitals", isError: false)
    static let signalWeak = ScanFeedback(icon: "exclamationmark.triangle.fill", message: "Weak signal — hold still in good lighting", isError: true)
}

class PresageManager: ObservableObject {
    @Published var latestReading: VitalsReading?
    /// Real-time feedback about scan quality (lighting, face position, etc.)
    @Published var scanFeedback: ScanFeedback?
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
        latestReading = nil
        scanFeedback = nil
        processor.startProcessing()
        processor.startRecording()

        // Observe status codes for real-time scan feedback
        processor.$lastStatusCode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] code in
                self?.scanFeedback = ScanFeedback.from(code)
            }
            .store(in: &cancellables)

        sdk.$metricsBuffer
            .dropFirst()          // skip stale initial value from previous session
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
        latestReading = nil
        scanFeedback = nil
    }
}
