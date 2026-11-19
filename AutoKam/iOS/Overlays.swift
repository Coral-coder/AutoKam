#if os(iOS)
import SwiftUI

/// The focus target. Green on a face (automatic), white on the middle of the frame or a tapped
/// point, yellow while the lens is moving.
struct FocusReticle: View {
    @ObservedObject var focus: FocusTracker

    var body: some View {
        GeometryReader { _ in
            if let rect = focus.rect {
                let color: Color = focus.adjusting ? .yellow : (focus.mode == .face ? .green : .white)
                ZStack(alignment: .topLeading) {
                    FocusBrackets()
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                    if focus.mode == .manual {
                        Text("AF")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(color)
                            .offset(x: 4, y: -14)
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .scaleEffect(focus.adjusting ? 1.1 : 1)
                .position(x: rect.midX, y: rect.midY)
                .animation(.easeOut(duration: 0.2), value: rect)
                .animation(.easeInOut(duration: 0.25), value: focus.adjusting)
            }
        }
    }
}

/// Four corner brackets.
struct FocusBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let l = min(rect.width, rect.height) * 0.25
        var p = Path()
        // top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // top-right
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        // bottom-left
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}

/// Stereo level meter (−60 to 0 dBFS) with peak hold. A mono mic shows on both bars.
struct VUMeter: View {
    @ObservedObject var meter: AudioMeter

    var body: some View {
        let silent = AudioMeter.Channel(average: -160, peak: -160)
        let left = meter.channels.first ?? silent
        let right = meter.channels.count >= 2 ? meter.channels[1] : left
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 4) {
                VUBar(level: left)
                VUBar(level: right)
            }
            .frame(width: 30, height: 190)
            Text(meter.isStereo ? "L  R" : "MONO")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }
}

private struct VUBar: View {
    let level: AudioMeter.Channel

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(min(1, max(0, (db + 60) / 60)))
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.15))
                LinearGradient(stops: [
                    .init(color: .green, location: 0),
                    .init(color: .green, location: 0.7),
                    .init(color: .yellow, location: 0.85),
                    .init(color: .red, location: 1),
                ], startPoint: .bottom, endPoint: .top)
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: h * fraction(level.average))
                }
                Rectangle()
                    .fill(level.peak > -3 ? Color.red : Color.white)
                    .frame(height: 2)
                    .offset(y: -h * fraction(level.peak))
                    .opacity(level.peak > -60 ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .animation(.linear(duration: 0.07), value: level)
    }
}

/// Which microphone is recording: green when it's the external one.
struct MicChip: View {
    @ObservedObject var meter: AudioMeter

    var body: some View {
        let detail = meter.isExternal ? (meter.isStereo ? " · stereo" : " · mono") : ""
        Label(meter.micName + detail, systemImage: meter.isExternal ? "mic.fill" : "iphone")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(meter.isExternal ? Color.green.opacity(0.8) : Color.black.opacity(0.5), in: Capsule())
            .foregroundStyle(.white)
    }
}
#endif
