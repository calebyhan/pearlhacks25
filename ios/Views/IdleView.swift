import SwiftUI

struct IdleView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("Visual911")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Emergency Video Call")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: {
                callManager.onSOSPressed()
            }) {
                Text("SOS")
                    .font(.system(size: 36, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(width: 160, height: 160)
                    .background(Circle().fill(Color.red))
            }

            Spacer()
        }
        .padding()
    }
}
