import SwiftUI

struct ScanningView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(2.0)

            Text("Scanning Vitals...")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Hold still, face the camera")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let vitals = callManager.lastVitals {
                VStack(spacing: 8) {
                    Text("HR: \(Int(vitals.hr)) bpm")
                        .font(.headline)
                    Text("Breathing: \(Int(vitals.breathing))/min")
                        .font(.headline)
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.1)))
            }

            Spacer()
        }
        .padding()
    }
}
