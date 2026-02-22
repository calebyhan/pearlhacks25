import SwiftUI
import SmartSpectraSwiftSDK

struct ScanningView: View {
    @EnvironmentObject var callManager: CallManager
    @ObservedObject private var vitalsProcessor = SmartSpectraVitalsProcessor.shared

    @State private var progress: Double = 0.0
    @State private var timer: Timer? = nil

    private let scanDuration: Double = 15.0

    var body: some View {
        ZStack {
            Color(red: 18/255, green: 18/255, blue: 18/255)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {

                // MARK: Header
                HStack {
                    Text("VISUAL 911")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Circle()
                        .fill(Color(white: 0.6))
                        .frame(width: 40, height: 40)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                // MARK: Title
                Text("Measuring Vitals")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 16)

                // MARK: Camera preview
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(white: 0.08))
                        .frame(height: 205)

                    if let image = vitalsProcessor.imageOutput {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 205)
                            .clipped()
                            .cornerRadius(10)
                            .scaleEffect(x: -1) // mirror front camera
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 48))
                                .foregroundColor(Color(white: 0.4))
                            Text("Starting camera…")
                                .font(.system(size: 13))
                                .foregroundColor(Color(white: 0.4))
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 12)

                // MARK: Progress bar
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(white: 0.85))
                        .frame(height: 10)
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 252/255, green: 87/255, blue: 87/255))
                        .frame(width: max(0, CGFloat(progress) * (UIScreen.main.bounds.width - 80)), height: 10)
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)

                // MARK: Vitals cards
                VStack(spacing: 16) {
                    VitalsCard(
                        icon: "heart.fill",
                        label: "Heart rate",
                        value: callManager.lastVitals.map { "\(Int($0.hr))" },
                        unit: "bpm",
                        stable: callManager.lastVitals?.hrStable
                    )

                    VitalsCard(
                        icon: "arrow.up.arrow.down",
                        label: "Breathing rate",
                        value: callManager.lastVitals.map { "\(Int($0.breathing))" },
                        unit: "/min",
                        stable: callManager.lastVitals?.brStable
                    )
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)

                Spacer()
            }
        }
        .onAppear { startProgress() }
        .onDisappear { timer?.invalidate() }
    }

    private func startProgress() {
        progress = 0.0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            progress = min(progress + 0.1 / scanDuration, 1.0)
            if progress >= 1.0 { t.invalidate() }
        }
    }
}

// MARK: - Vitals Card

private struct VitalsCard: View {
    let icon: String
    let label: String
    let value: String?   // nil = still measuring
    let unit: String
    let stable: Bool?    // nil = no reading yet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                Text(label)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(.white)
            }

            HStack(alignment: .center, spacing: 10) {
                if let value {
                    Text(value)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                    Text(unit)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.white)
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.1)
                    Text("Measuring…")
                        .font(.system(size: 16))
                        .foregroundColor(Color(white: 0.6))
                }
            }

            if let stable {
                HStack(spacing: 4) {
                    Circle()
                        .fill(stable ? Color(red: 34/255, green: 200/255, blue: 100/255) : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(stable ? "Signal stable" : "Signal weak")
                        .font(.system(size: 13))
                        .foregroundColor(stable ? Color(red: 34/255, green: 180/255, blue: 80/255) : .orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(white: 0.85), lineWidth: 1)
        )
    }
}
