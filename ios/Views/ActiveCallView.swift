import SwiftUI

struct ActiveCallView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        VStack(spacing: 16) {
            // Status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)

            // Vitals display
            if let vitals = callManager.lastVitals {
                HStack(spacing: 24) {
                    VStack {
                        Text("\(Int(vitals.hr))")
                            .font(.system(size: 48, weight: .bold))
                        Text("bpm")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    VStack {
                        Text("\(Int(vitals.breathing))")
                            .font(.system(size: 48, weight: .bold))
                        Text("/min")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }

            Spacer()

            // End call button
            Button(action: {
                callManager.endCall()
            }) {
                Text("End Call")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.red))
            }
            .padding()
        }
    }

    private var statusColor: Color {
        switch callManager.state {
        case .initiating: return .yellow
        case .connecting: return .orange
        case .active: return .green
        default: return .gray
        }
    }

    private var statusText: String {
        switch callManager.state {
        case .initiating: return "Waiting for dispatcher..."
        case .connecting: return "Connecting..."
        case .active: return "Connected"
        default: return ""
        }
    }
}
