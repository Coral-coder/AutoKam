#if os(iOS)
import SwiftUI

/// The focus target. Green on a face (automatic), white on the middle of the frame or a tapped
/// point, yellow while the lens is moving.
struct FocusReticle: View {
    @ObservedObject var focus: FocusTracker

    var body: some View {
        GeometryReader { _ in
            if let rect = focus.rect {
                let color: Color = focus.adjusting ? .yellow
                    : focus.mode == .face ? .green
                    : focus.mode == .object ? .cyan : .white
                ZStack(alignment: .topLeading) {
                    FocusBrackets()
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                    if focus.mode == .object {
                        Text("OBJECT")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(color)
                            .offset(x: 4, y: -14)
                    } else if focus.mode == .manual {
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

#if os(iOS)
import CoreMotion

/// How far the phone is tilted off level (roll), whichever way it's held.
final class LevelMeter: ObservableObject {
    /// Degrees off level; nil when the phone is lying flat and roll means nothing.
    @Published private(set) var degrees: Double?
    private let motion = CMMotionManager()
    private var smoothed: Double?

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            if abs(g.z) > 0.9 {
                if self.degrees != nil { self.degrees = nil; self.smoothed = nil }
                return
            }
            // Direction of gravity on the screen, then how far it is from the nearest
            // straight down (portrait, upside down, or either landscape).
            let angle = atan2(g.y, g.x) * 180 / .pi
            var off = angle.truncatingRemainder(dividingBy: 90)
            if off > 45 { off -= 90 } else if off < -45 { off += 90 }
            let value = self.smoothed.map { $0 * 0.75 + off * 0.25 } ?? off
            self.smoothed = value
            if let current = self.degrees, abs(current - value) < 0.1 { return }
            self.degrees = value
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}

/// A horizon line across the middle of the frame: it stays parallel to the real horizon and
/// turns green when the phone is level.
struct LevelIndicator: View {
    @ObservedObject var level: LevelMeter

    var body: some View {
        if let degrees = level.degrees {
            let isLevel = abs(degrees) < 0.7
            let color: Color = isLevel ? .green : .white
            ZStack {
                // Fixed marks: where level is.
                HStack {
                    Capsule().fill(color.opacity(0.9)).frame(width: 26, height: 3)
                    Spacer()
                    Capsule().fill(color.opacity(0.9)).frame(width: 26, height: 3)
                }
                .frame(width: 260)
                // The real horizon.
                Capsule()
                    .fill(color)
                    .frame(width: 180, height: isLevel ? 3 : 2)
                    .rotationEffect(.degrees(isLevel ? 0 : -degrees))
                    .shadow(color: .black.opacity(0.5), radius: 1)
                Text(isLevel ? "LEVEL" : String(format: "%.1f°", abs(degrees)))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .offset(y: 16)
            }
            .animation(.easeOut(duration: 0.1), value: degrees)
            .allowsHitTesting(false)
        }
    }
}
#endif
