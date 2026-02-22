import SwiftUI

/// EKG waveform logo matching the web app's logo.svg
/// Path: M3 12h4l3 7 4-14 3 7h4 in a 24×24 viewBox
struct EKGLogoView: View {
    var strokeColor: Color = .black
    var backgroundColor: Color = .white
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: size, height: size)
            EKGShape()
                .stroke(strokeColor, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round, lineJoin: .round))
                .padding(size * 0.18)
                .frame(width: size, height: size)
        }
    }
}

private struct EKGShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Points from SVG path M3 12h4l3 7 4-14 3 7h4 in 24×24 viewBox
        let pts: [(CGFloat, CGFloat)] = [(3,12),(7,12),(10,19),(14,5),(17,12),(21,12)]
        let scaleX = rect.width / 24
        let scaleY = rect.height / 24

        var p = Path()
        let first = pts[0]
        p.move(to: CGPoint(x: first.0 * scaleX + rect.minX, y: first.1 * scaleY + rect.minY))
        for pt in pts.dropFirst() {
            p.addLine(to: CGPoint(x: pt.0 * scaleX + rect.minX, y: pt.1 * scaleY + rect.minY))
        }
        return p
    }
}
