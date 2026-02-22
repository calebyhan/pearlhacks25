import SwiftUI

struct ContentView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch callManager.state {
            case .idle:
                IdleView()
            case .scanning:
                ScanningView()
            case .initiating, .connecting:
                InitiatingView()
            case .active:
                ActiveCallView()
            case .cleanup:
                ProgressView("Ending call…")
                    .foregroundColor(.white)
            }
        }
        .preferredColorScheme(.dark)
    }
}
