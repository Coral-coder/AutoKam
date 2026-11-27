#if os(iOS)
import Foundation
import Vision
import QuartzCore
import CoreVideo
import ImageIO

/// How picky the recognizer is. Medium is the default.
///
/// Fingers are judged by how bent their joints are, which doesn't change when the hand is
/// tilted, near or far, so a close-enough gesture still counts.
struct GestureTuning {
    var hold: Double           // seconds the pose must be held
    var jointConfidence: Float // how sure Vision must be about each joint
    var straight: CGFloat      // a joint this open (degrees) counts as straight
    var bent: CGFloat          // a joint this closed (degrees) counts as folded
    var maxTilt: CGFloat       // how far from vertical the hand may lean (degrees)
    var stillness: CGFloat     // how far the hand may drift during the hold (hand lengths)
    var minFrames: Int

    static let high = GestureTuning(hold: 0.3, jointConfidence: 0.2, straight: 140, bent: 130,
                                    maxTilt: 75, stillness: 0.9, minFrames: 3)
    static let medium = GestureTuning(hold: 0.4, jointConfidence: 0.25, straight: 148, bent: 122,
                                      maxTilt: 65, stillness: 0.7, minFrames: 4)
    static let low = GestureTuning(hold: 0.6, jointConfidence: 0.35, straight: 158, bent: 110,
                                   maxTilt: 50, stillness: 0.5, minFrames: 6)
}

struct GestureProgress: Equatable {
    var gesture: HandGesture
    var progress: Double
}

/// Looks for ✋ / ✊ / 👍 / ✌️ held for `holdDuration` seconds, checking about 20 times a second
/// on the phone itself. Callbacks arrive on the main queue.
final class GestureDetector {
    var enabled = true
    /// Thresholds and hold time (Settings → Gestures → Sensitivity).
    var tuning = GestureTuning.medium
    var onProgress: ((GestureProgress?) -> Void)?
    /// What the phone sees per finger, for the on-screen gesture debug readout. Main queue.
    var onDebug: ((String) -> Void)?
    var debug = false
    /// The gesture and when it first appeared (used to trim it off a kept take).
    var onGesture: ((HandGesture, Date) -> Void)?

    private let queue = DispatchQueue(label: "autokam.vision", qos: .userInteractive)
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()
    private let lock = NSLock()
    private var busy = false
    private var lastRun: CFTimeInterval = 0

    // Vision queue state
    private var current: HandGesture?
    private var since: CFTimeInterval = 0
    private var firstSeen = Date()
    private var misses = 0
    private var cooldownUntil: CFTimeInterval = 0

    /// Gestures she's switched off in Settings.
    var disabled: Set<HandGesture> = []
    /// Notice a hand holding something up to the camera (and ignore gestures meanwhile).
    var detectShowing = true
    /// Gestures need both hands making the same shape at once. One hand on its own (holding
    /// something, talking) can't trigger anything.
    var requireBothHands = true
    /// Where a shown object is, in upright frame coordinates (0–1, origin top-left), or nil
    /// once the hand has gone. Main queue.
    var onShowing: ((CGPoint?) -> Void)?

    // Showing an object (vision queue)
    private var showingActive = false
    private var showingSince: CFTimeInterval = 0
    private var showingAnchor: CGPoint?
    private var lastHandSeen: CFTimeInterval = 0
    private var lastShownPoint: CGPoint?

    private struct Sighting {
        var gesture: HandGesture
        var wrist: CGPoint
        var scale: CGFloat
    }
    private var anchor: CGPoint?       // where the hand was when this hold began
    private var frames = 0             // detections in this hold

    func process(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        if busy || now - lastRun < 0.045 {
            lock.unlock()
            return
        }
        busy = true
        lastRun = now
        lock.unlock()

        // Vision reports points in the upright picture, so use its proportions.
        let sideways = orientation == .right || orientation == .left
        let width = CGFloat(sideways ? CVPixelBufferGetHeight(pixelBuffer) : CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(sideways ? CVPixelBufferGetWidth(pixelBuffer) : CVPixelBufferGetHeight(pixelBuffer))
        queue.async { [self] in
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            var found: Sighting?
            var shown: (point: CGPoint, scale: CGFloat)?
            var handSeen = false
            var debugLines: [String] = []
            let aspect = height > 0 ? width / height : 1
            if (try? handler.perform([request])) != nil, let hands = request.results {
                var sightings: [Sighting] = []
                for hand in hands where hand.confidence >= 0.2 {
                    handSeen = true
                    let t = tuning
                    if debug { debugLines.append(Self.describe(hand, aspect: aspect, t: t)) }
                    if let sighting = Self.classify(hand, aspect: aspect, t: t) {
                        if !disabled.contains(sighting.gesture) { sightings.append(sighting) }
                    } else if shown == nil, let object = Self.showingObject(hand, aspect: aspect) {
                        shown = object
                    }
                }
                found = requireBothHands ? Self.bothHands(sightings) : sightings.first
            }
            if debug {
                let text = debugLines.isEmpty ? "no hand" : debugLines.joined(separator: "\n")
                DispatchQueue.main.async { self.onDebug?(text) }
            }
            let now = CACurrentMediaTime()
            updateShowing(shown, handSeen: handSeen, aspect: aspect, now: now)
            // While she's holding something up, nothing that hand does is a gesture.
            update(showingActive ? nil : found, now: now)
            lock.lock(); busy = false; lock.unlock()
        }
    }

    private func hold(for gesture: HandGesture) -> Double {
        // A hand passes through a fist on its way to a thumbs-up, so a fist needs a bit longer.
        gesture == .fist ? tuning.hold * 1.3 : tuning.hold
    }

    private func reset() {
        current = nil
        anchor = nil
        frames = 0
    }

    private func update(_ sighting: Sighting?, now: CFTimeInterval) {
        if now < cooldownUntil {
            reset()
            report(nil)
            return
        }
        guard let sighting else {
            // A couple of dropped frames are forgiven; more and the hold starts over.
            if current != nil, misses < 2 {
                misses += 1
                return
            }
            misses = 0
            reset()
            report(nil)
            return
        }
        misses = 0
        // A hand that's moving (talking, waving) isn't making a gesture: it has to stay put.
        if sighting.gesture != current || anchor.map({ Hand.d($0, sighting.wrist) > sighting.scale * tuning.stillness }) ?? true {
            current = sighting.gesture
            anchor = sighting.wrist
            since = now
            firstSeen = Date()
            frames = 0
        }
        frames += 1
        let progress = min(1, (now - since) / hold(for: sighting.gesture))
        if progress >= 1 && frames >= tuning.minFrames {
            let seenAt = firstSeen
            let gesture = sighting.gesture
            reset()
            cooldownUntil = now + 1.5
            report(nil)
            DispatchQueue.main.async { self.onGesture?(gesture, seenAt) }
        } else {
            report(GestureProgress(gesture: sighting.gesture, progress: min(progress, 0.95)))
        }
    }

    private func updateShowing(_ shown: (point: CGPoint, scale: CGFloat)?, handSeen: Bool, aspect: CGFloat, now: CFTimeInterval) {
        guard detectShowing else {
            if showingActive { showingActive = false; reportShowing(nil) }
            return
        }
        if handSeen { lastHandSeen = now }
        if let shown {
            if showingActive {
                // Follow the object if it moves.
                if let last = lastShownPoint, Hand.d(last, shown.point) > 0.04 {
                    lastShownPoint = shown.point
                    reportShowing(shown.point, aspect: aspect)
                }
            } else if let anchor = showingAnchor, Hand.d(anchor, shown.point) < shown.scale * 0.5 {
                if now - showingSince > 0.5 {
                    showingActive = true
                    lastShownPoint = shown.point
                    reset()
                    report(nil)
                    reportShowing(shown.point, aspect: aspect)
                }
            } else {
                showingAnchor = shown.point
                showingSince = now
            }
        } else if !showingActive {
            showingAnchor = nil
        }
        // Done showing once the hand has left the frame.
        if showingActive && now - lastHandSeen > 0.7 {
            showingActive = false
            showingAnchor = nil
            lastShownPoint = nil
            reportShowing(nil)
        }
    }

    /// Converts from square coordinates (y up) to frame coordinates (0–1, origin top-left).
    private func reportShowing(_ point: CGPoint?, aspect: CGFloat = 1) {
        let framePoint = point.map { CGPoint(x: $0.x / max(aspect, 0.01), y: 1 - $0.y) }
        DispatchQueue.main.async { self.onShowing?(framePoint) }
    }

    private func report(_ progress: GestureProgress?) {
        DispatchQueue.main.async { self.onProgress?(progress) }
    }

    // MARK: - Classification

    private enum Finger: Equatable { case straight, folded, between, unseen }

    /// One hand's joints in square coordinates (x scaled by the aspect ratio), y pointing up.
    private struct Hand {
        let points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]
        let aspect: CGFloat
        let t: GestureTuning

        static func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        /// A joint's position if Vision is reasonably sure of it.
        func p(_ joint: VNHumanHandPoseObservation.JointName, _ minimum: Float? = nil) -> CGPoint? {
            guard let point = points[joint], point.confidence >= (minimum ?? t.jointConfidence) else { return nil }
            return CGPoint(x: point.location.x * aspect, y: point.location.y)
        }

        /// Angle at `b` between `a` and `c`, in degrees: 180 is a straight line.
        static func angle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y), v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let len = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
            guard len > 0 else { return 180 }
            let cosine = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / len))
            return acos(cosine) * 180 / .pi
        }

        var wrist: CGPoint? { p(.wrist) }
        var middleMCP: CGPoint? { p(.middleMCP) }
        var scale: CGFloat? {
            guard let wrist, let middleMCP else { return nil }
            return Self.d(wrist, middleMCP)
        }

        /// How far the hand leans from vertical (wrist to middle knuckle), in degrees.
        var tilt: CGFloat? {
            guard let wrist, let middleMCP else { return nil }
            let dx = middleMCP.x - wrist.x, dy = middleMCP.y - wrist.y
            return abs(atan2(dx, dy) * 180 / .pi)
        }

        func finger(_ mcp: VNHumanHandPoseObservation.JointName, _ pip: VNHumanHandPoseObservation.JointName,
                    _ dip: VNHumanHandPoseObservation.JointName, _ tip: VNHumanHandPoseObservation.JointName) -> Finger {
            guard let wrist, let m = p(mcp), let pi = p(pip) else { return .unseen }
            // In a fist the fingertips are hidden; their rough positions are still useful.
            guard let di = p(dip, 0.05), let ti = p(tip, 0.05) else { return .unseen }
            let atPIP = Self.angle(m, pi, di)
            let atDIP = Self.angle(pi, di, ti)
            let tipOut = Self.d(wrist, ti) > Self.d(wrist, pi)
            if atPIP >= t.straight && atDIP >= t.straight - 25 && tipOut { return .straight }
            if atPIP <= t.bent || !tipOut { return .folded }
            return .between
        }

        var index: Finger { finger(.indexMCP, .indexPIP, .indexDIP, .indexTip) }
        var middle: Finger { finger(.middleMCP, .middlePIP, .middleDIP, .middleTip) }
        var ring: Finger { finger(.ringMCP, .ringPIP, .ringDIP, .ringTip) }
        var little: Finger { finger(.littleMCP, .littlePIP, .littleDIP, .littleTip) }

        /// Thumb straight and away from the hand.
        var thumbOut: Bool {
            guard let cmc = p(.thumbCMC, 0.1), let mp = p(.thumbMP), let ip = p(.thumbIP), let tip = p(.thumbTip),
                  let indexMCP = p(.indexMCP), let scale else { return false }
            return Self.angle(mp, ip, tip) >= t.straight - 15
                && Self.angle(cmc, mp, ip) >= t.straight - 25
                && Self.d(tip, indexMCP) > scale * 0.45
        }

        /// Thumb pointing up (within 40° of vertical) and above the rest of the hand.
        var thumbPointsUp: Bool {
            guard let mp = p(.thumbMP), let tip = p(.thumbTip), let scale else { return false }
            let dx = tip.x - mp.x, dy = tip.y - mp.y
            guard dy > scale * 0.3, abs(atan2(dx, dy) * 180 / .pi) < 40 else { return false }
            let others: [VNHumanHandPoseObservation.JointName] = [.indexTip, .middleTip, .ringTip, .littleTip, .indexPIP, .middlePIP, .wrist]
            return others.compactMap { p($0, 0.05) }.allSatisfy { tip.y > $0.y }
        }
    }

    private static func classify(_ observation: VNHumanHandPoseObservation, aspect: CGFloat, t: GestureTuning) -> Sighting? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        let h = Hand(points: points, aspect: aspect, t: t)
        guard let wrist = h.wrist, let scale = h.scale, scale > 0.02, let tilt = h.tilt else { return nil }
        let fingers = [h.index, h.middle, h.ring, h.little]
        let folded = fingers.allSatisfy { $0 == .folded }

        // 👍 fist with the thumb straight and pointing up (the hand itself may be sideways).
        if folded && h.thumbOut && h.thumbPointsUp {
            return Sighting(gesture: .thumbsUp, wrist: wrist, scale: scale)
        }
        // The other gestures are shown with the hand held up, leaning no more than maxTilt.
        guard tilt <= t.maxTilt else { return nil }

        // ✋ all four fingers straight and the thumb out.
        if fingers.allSatisfy({ $0 == .straight }) && h.thumbOut {
            return Sighting(gesture: .openPalm, wrist: wrist, scale: scale)
        }
        // ✌️ index and middle straight and apart, ring and little folded.
        if h.index == .straight && h.middle == .straight && h.ring == .folded && h.little == .folded,
           let a = h.p(.indexTip), let b = h.p(.middleTip), Hand.d(a, b) > scale * 0.25 {
            return Sighting(gesture: .peace, wrist: wrist, scale: scale)
        }
        // ✊ all four fingers folded tight (tips near their knuckles — a hand wrapped around
        // something you're holding up is wider than that) and the thumb not sticking up.
        let pairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] =
            [(.indexTip, .indexMCP), (.middleTip, .middleMCP), (.ringTip, .ringMCP), (.littleTip, .littleMCP)]
        let tight = pairs.filter { tip, mcp in
            guard let a = h.p(tip, 0.05), let b = h.p(mcp, 0.05) else { return false }
            return Hand.d(a, b) < scale * 0.75
        }.count >= 3
        if folded && tight && !h.thumbPointsUp {
            return Sighting(gesture: .fist, wrist: wrist, scale: scale)
        }
        return nil
    }

    /// Two separate hands showing the same gesture. Reported at the point between them.
    private static func bothHands(_ sightings: [Sighting]) -> Sighting? {
        guard sightings.count >= 2 else { return nil }
        let a = sightings[0], b = sightings[1]
        let scale = max(a.scale, b.scale)
        // Really two hands, not one hand seen twice.
        guard a.gesture == b.gesture, Hand.d(a.wrist, b.wrist) > scale * 1.2 else { return nil }
        let middle = CGPoint(x: (a.wrist.x + b.wrist.x) / 2, y: (a.wrist.y + b.wrist.y) / 2)
        return Sighting(gesture: a.gesture, wrist: middle, scale: scale)
    }

    /// A one-line readout of what the phone sees, for Settings → Gestures → Show what it sees.
    private static func describe(_ observation: VNHumanHandPoseObservation, aspect: CGFloat, t: GestureTuning) -> String {
        guard let points = try? observation.recognizedPoints(.all) else { return "hand: no joints" }
        let h = Hand(points: points, aspect: aspect, t: t)
        func mark(_ f: Finger) -> String {
            switch f {
            case .straight: return "up"
            case .folded: return "fold"
            case .between: return "half"
            case .unseen: return "?"
            }
        }
        let tilt = h.tilt.map { String(format: "%.0f°", $0) } ?? "?"
        let result = classify(observation, aspect: aspect, t: t).map { $0.gesture.emoji } ?? "—"
        return "I \(mark(h.index))  M \(mark(h.middle))  R \(mark(h.ring))  L \(mark(h.little))  "
            + "thumb \(h.thumbOut ? (h.thumbPointsUp ? "up" : "out") : "in")  tilt \(tilt)  "
            + String(format: "conf %.2f", observation.confidence) + "  → \(result)"
    }

    private static func showingObject(_ observation: VNHumanHandPoseObservation, aspect: CGFloat) -> (point: CGPoint, scale: CGFloat)? {
        guard let points = try? observation.recognizedPoints(.all), points.count >= 15 else { return nil }
        let all = Array(points.values)
        let hidden = all.filter { $0.confidence < 0.3 }.count
        guard hidden >= 5 else { return nil } // a clear, uncovered hand isn't showing anything
        func sq(_ p: VNRecognizedPoint) -> CGPoint { CGPoint(x: p.location.x * aspect, y: p.location.y) }
        guard let wrist = points[.wrist], wrist.confidence >= 0.3 else { return nil }
        let knuckles = [VNHumanHandPoseObservation.JointName.indexMCP, .middleMCP, .ringMCP, .littleMCP]
            .compactMap { points[$0] }
        guard knuckles.count == 4 else { return nil }
        let center = CGPoint(x: all.map { sq($0).x }.reduce(0, +) / CGFloat(all.count),
                             y: all.map { sq($0).y }.reduce(0, +) / CGFloat(all.count))
        let scale = Hand.d(sq(wrist), sq(knuckles[1]))
        // Close enough to be presenting something, held up, and not just poking in at the edge.
        let raw = CGPoint(x: center.x / max(aspect, 0.01), y: center.y)
        guard scale > 0.05, sq(knuckles[1]).y > sq(wrist).y,
              raw.x > 0.08, raw.x < 0.92, raw.y > 0.08, raw.y < 0.92 else { return nil }
        return (center, scale)
    }

}
#endif
