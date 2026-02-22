import SwiftUI
import CoreLocation

struct IdleView: View {
    @EnvironmentObject var callManager: CallManager

    @State private var locationString: String = "Fetching location…"
    private let userName = "Caleb Han"

    private let geocoder = CLGeocoder()
    private let locationManager = CLLocationManager()

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

                // MARK: Greeting
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hello,")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.white)
                    Text(userName)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 29)
                .padding(.top, 24)

                Spacer()

                // MARK: SOS Section
                VStack(spacing: 16) {
                    Text("Call 911")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white)

                    // Vitals status badge
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(red: 159/255, green: 250/255, blue: 189/255))
                            .frame(width: 10, height: 10)
                        Text("Ready to scan vitals")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(red: 34/255, green: 103/255, blue: 57/255))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(red: 207/255, green: 255/255, blue: 223/255).opacity(0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color(red: 159/255, green: 250/255, blue: 189/255), lineWidth: 1)
                            )
                    )

                    // SOS button
                    Button(action: {
                        callManager.onSOSPressed()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 255/255, green: 95/255, blue: 87/255))
                                .frame(width: 270, height: 270)
                            Text("SOS")
                                .font(.system(size: 60, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }

                    Text("Press the button if there is an emergency")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 251)
                }
                .frame(maxWidth: .infinity)

                Spacer()

                // MARK: Location
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your current location:")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                    Text(locationString)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.white)
                        .frame(maxWidth: 270, alignment: .leading)
                }
                .padding(.horizontal, 29)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            fetchLocation()
        }
    }

    private func fetchLocation() {
        guard let location = locationManager.location else { return }
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            guard let p = placemarks?.first else { return }
            var parts: [String] = []
            if let number = p.subThoroughfare { parts.append(number) }
            if let street = p.thoroughfare { parts.append(street) }
            if let city = p.locality { parts.append(city) }
            if let state = p.administrativeArea { parts.append(state) }
            if let zip = p.postalCode { parts.append(zip) }
            if let country = p.country { parts.append(country) }
            DispatchQueue.main.async {
                locationString = parts.joined(separator: ", ")
            }
        }
    }
}
