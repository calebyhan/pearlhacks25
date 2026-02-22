import SwiftUI
import CoreLocation

struct InitiatingView: View {
    @EnvironmentObject var callManager: CallManager

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
                    EKGLogoView(size: 40)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                // MARK: Title
                Text("Vitals Captured")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 16)

                // MARK: Checkmark
                ZStack {
                    Circle()
                        .fill(Color(red: 159/255, green: 220/255, blue: 180/255))
                        .frame(width: 100, height: 100)
                    Image(systemName: "checkmark")
                        .font(.system(size: 35, weight: .medium))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

                Text("Connecting dispatcher...")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)

                // MARK: Vitals cards (side by side)
                HStack(spacing: 12) {
                    MiniVitalsCard(
                        icon: "heart.fill",
                        label: "Heart rate",
                        value: callManager.lastVitals.map { "\(Int($0.hr))" } ?? "—",
                        unit: "bpm",
                        stable: callManager.lastVitals?.hrStable
                    )
                    MiniVitalsCard(
                        icon: "arrow.up.arrow.down",
                        label: "Breathing",
                        value: callManager.lastVitals.map { "\(Int($0.breathing))" } ?? "—",
                        unit: "/min",
                        stable: callManager.lastVitals?.brStable
                    )
                }
                .padding(.horizontal, 33)
                .padding(.top, 20)

                // MARK: Location card
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                        Text("Location")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(.white)
                    }
                    Text(coordinateString)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(.white)
                    Text("Location shared with dispatcher")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(white: 0.85), lineWidth: 1)
                )
                .padding(.horizontal, 33)
                .padding(.top, 16)

                // MARK: Status indicator
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(red: 252/255, green: 180/255, blue: 87/255))
                        .frame(width: 10, height: 10)
                    Text("Waiting for dispatcher to answer...")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 33)
                .padding(.top, 20)

                Spacer()

                // MARK: Cancel button
                Button(action: {
                    callManager.endCall()
                }) {
                    Text("Cancel emergency call")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 49)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(red: 252/255, green: 87/255, blue: 87/255))
                        )
                }
                .padding(.horizontal, 43)
                .padding(.bottom, 40)
            }
        }
    }

    private var coordinateString: String {
        guard let loc = callManager.lastLocation else { return "Fetching location…" }
        let lat = loc.latitude
        let lng = loc.longitude
        let latStr = String(format: "%.4f° %@", abs(lat), lat >= 0 ? "N" : "S")
        let lngStr = String(format: "%.4f° %@", abs(lng), lng >= 0 ? "E" : "W")
        return "\(latStr), \(lngStr)"
    }
}

// MARK: - Mini Vitals Card

private struct MiniVitalsCard: View {
    let icon: String
    let label: String
    let value: String
    let unit: String
    let stable: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                Text(label)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(.white)
            }
            Text(value)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
            Text(unit)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(.white)
            if let stable {
                HStack(spacing: 4) {
                    Circle()
                        .fill(stable ? Color(red: 34/255, green: 200/255, blue: 100/255) : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(stable ? "Stable" : "Weak")
                        .font(.system(size: 12))
                        .foregroundColor(stable ? Color(red: 34/255, green: 180/255, blue: 80/255) : .orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(white: 0.85), lineWidth: 1)
        )
    }
}
