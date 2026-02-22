import SwiftUI
import WebRTC

struct ActiveCallView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 18/255, green: 18/255, blue: 18/255)
                .ignoresSafeArea()

            // MARK: Full-screen local video feed
            RTCLocalVideoView(manager: callManager)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .ignoresSafeArea(edges: .top)

            // MARK: Overlays on the video
            VStack {
                // Camera icon — top-right corner of video area
                HStack {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(white: 0.4).opacity(0.54))
                            .frame(width: 40, height: 40)
                        Image(systemName: "camera.rotate")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                    }
                }
                .padding(.top, 18)
                .padding(.trailing, 10)

                Spacer()

                // "Dispatcher can see your video and location"
                Text("Dispatcher can see your video and location")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Color(white: 0.51))
                    .padding(.bottom, 12)
            }

            // MARK: Bottom controls
            HStack(spacing: 0) {
                // Mute
                Button(action: { callManager.toggleMute() }) {
                    Text(callManager.isMuted ? "Unmute" : "Mute")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.black)
                        .frame(width: 140, height: 49)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color(white: 0.51), lineWidth: 1)
                                )
                        )
                }

                Spacer()

                // End call
                Button(action: { callManager.endCall() }) {
                    Text("End call")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.white)
                        .frame(width: 140, height: 49)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(red: 252/255, green: 87/255, blue: 87/255))
                        )
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 40)
        }
    }
}
