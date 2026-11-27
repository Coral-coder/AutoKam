#if os(iOS)
import Foundation
import Vision
import QuartzCore
import CoreVideo
import ImageIO

/// How picky the recognizer is. Medium is the default.
struct GestureTuning {
    var hold: Double           // seconds the pose must be held
    var jointConfidence: Float // how sure Vision must be about each joint
    var handConfidence: Float
    var fingerUp: CGFloat      // fingertip above its knuckle, in hand lengths
    var fingerLength: CGFloat  // straight finger: tip-to-knuckle, in hand lengths
    var foldedLength: CGFloat  // folded finger: tip within this of its knuckle
    var stillness: CGFloat     // how far the hand may drift during the hold
    var minFrames: Int

    static let high = GestureTuning(hold: 0.3, jointConfidence: 0.25, handConfidence: 0.25, fingerUp: 0.3,
                                    fingerLength: 0.5, foldedLength: 0.85, stillness: 0.8, minFrames: 3)
    static let medium = GestureTuning(hold: 0.4, jointConfidence: 0.3, handConfidence: 0.3, fingerUp: 0.4,
                                      fingerLength: 0.55, foldedLength: 0.78, stillness: 0.65, minFrames: 4)
    static let low = GestureTuning(hold: 0.6, jointConfidence: 0.45, handConfidence: 0.45, fingerUp: 0.55,
                                   fingerLength: 0.65, foldedLength: 0.68, stillness: 0.45, minFrames: 6)
}

struct GestureProgress: Equatable {
    var gesture: HandGesture
    var progress: Double
}

/// Looks for ✋ / ✊ / 👍 / ✌️ held for `holdDuration` seconds, checking about 20 times a second
/// on the phone itself. Frames must be upright. Callbacks arrive on the main queue.
final class GestureDetector {
    var enabled = true
    /// Thresholds and hold time (Settings → Gestures → Sensitivity).
    var tuning = GestureTuning.medium
    var onProgress: ((GestureProgress?) -> Void)?
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
            let aspect = height > 0 ? width / height : 1
            if (try? handler.perform([request])) != nil, let hands = request.results {
                for hand in hands where hand.confidence >= 0.3 {
                    handSeen = true
                    let t = tuning
                    if let sighting = Self.classify(hand, aspect: aspect, t: t) {
                        if !disabled.contains(sighting.gesture) && found == nil { found = sighting }
                    } else if shown == nil, let object = Self.showingObject(hand, aspect: aspect) {
                        shown = object
                    }
                }
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
            // One dropped frame is forgiven; two and the hold starts over.
            if current != nil, misses < 1 {
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
    //
    // Deliberately strict: a gesture only counts when every joint is clearly visible, the hand
    // is upright and the shape is unmistakable. Ordinary hands — resting, talking, holding
    // something — must never match.

    /// Hand joints in square coordinates (x scaled by the aspect ratio), y pointing up.
    private struct Hand {
        var wrist, thumbTip, thumbIP, thumbMP: CGPoint
        var indexTip, indexPIP, indexMCP: CGPoint
        var middleTip, middlePIP, middleMCP: CGPoint
        var ringTip, ringPIP, ringMCP: CGPoint
        var littleTip, littlePIP, littleMCP: CGPoint

        /// `tipConfidence` applies to fingertips, `minConfidence` to everything else.
        init?(_ points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint], aspect: CGFloat,
              minConfidence: Float, tipConfidence: Float) {
            func p(_ joint: VNHumanHandPoseObservation.JointName, _ min: Float) -> CGPoint? {
                guard let point = points[joint], point.confidence >= min else { return nil }
                return CGPoint(x: point.location.x * aspect, y: point.location.y)
            }
            guard let wrist = p(.wrist, minConfidence), let thumbTip = p(.thumbTip, tipConfidence),
                  let thumbIP = p(.thumbIP, minConfidence), let thumbMP = p(.thumbMP, minConfidence),
                  let indexTip = p(.indexTip, tipConfidence), let indexPIP = p(.indexPIP, minConfidence), let indexMCP = p(.indexMCP, minConfidence),
                  let middleTip = p(.middleTip, tipConfidence), let middlePIP = p(.middlePIP, minConfidence), let middleMCP = p(.middleMCP, minConfidence),
                  let ringTip = p(.ringTip, tipConfidence), let ringPIP = p(.ringPIP, minConfidence), let ringMCP = p(.ringMCP, minConfidence),
                  let littleTip = p(.littleTip, tipConfidence), let littlePIP = p(.littlePIP, minConfidence), let littleMCP = p(.littleMCP, minConfidence)
            else { return nil }
            self.wrist = wrist; self.thumbTip = thumbTip; self.thumbIP = thumbIP; self.thumbMP = thumbMP
            self.indexTip = indexTip; self.indexPIP = indexPIP; self.indexMCP = indexMCP
            self.middleTip = middleTip; self.middlePIP = middlePIP; self.middleMCP = middleMCP
            self.ringTip = ringTip; self.ringPIP = ringPIP; self.ringMCP = ringMCP
            self.littleTip = littleTip; self.littlePIP = littlePIP; self.littleMCP = littleMCP
        }

        static func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        var scale: CGFloat { Self.d(wrist, middleMCP) }

        /// Straight and pointing up.
        func straightUp(_ tip: CGPoint, _ pip: CGPoint, _ mcp: CGPoint, _ t: GestureTuning) -> Bool {
            Self.d(wrist, tip) > Self.d(wrist, pip) * 1.08
                && Self.d(tip, mcp) > scale * t.fingerLength
                && tip.y - mcp.y > scale * t.fingerUp
        }
        /// Folded down into the palm.
        func folded(_ tip: CGPoint, _ pip: CGPoint, _ mcp: CGPoint, _ t: GestureTuning) -> Bool {
            Self.d(wrist, tip) < Self.d(wrist, pip) * 1.05 && Self.d(tip, mcp) < scale * t.foldedLength
        }
        func allFolded(_ t: GestureTuning) -> Bool {
            folded(indexTip, indexPIP, indexMCP, t) && folded(middleTip, middlePIP, middleMCP, t)
                && folded(ringTip, ringPIP, ringMCP, t) && folded(littleTip, littlePIP, littleMCP, t)
        }
        /// Hand held up: knuckles above the wrist.
        var upright: Bool { middleMCP.y - wrist.y > scale * 0.5 }

        func isThumbsUp(_ t: GestureTuning) -> Bool {
            guard allFolded(t) else { return false }
            let dy = thumbTip.y - thumbMP.y
            let dx = abs(thumbTip.x - thumbMP.x)
            let others = [indexTip, middleTip, ringTip, littleTip, indexPIP, middlePIP, indexMCP, middleMCP, wrist]
            return Self.d(thumbTip, thumbMP) > scale * 0.35
                && dy > scale * 0.35 && dy > dx * 1.3
                && thumbTip.y > thumbMP.y
                && others.allSatisfy { thumbTip.y > $0.y + scale * 0.1 }
        }
    }

    /// A raised hand that's partly hidden — something held up in front of the palm. Returns the
    /// middle of the hand (where the object is) in square coordinates, and the hand's size.
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

    private static func classify(_ observation: VNHumanHandPoseObservation, aspect: CGFloat, t: GestureTuning) -> Sighting? {
        guard observation.confidence >= t.handConfidence, let points = try? observation.recognizedPoints(.all) else { return nil }

        if let h = Hand(points, aspect: aspect, minConfidence: t.jointConfidence, tipConfidence: t.jointConfidence), h.scale > 0.025 {
            let s = h.scale
            if h.isThumbsUp(t) {
                return Sighting(gesture: .thumbsUp, wrist: h.wrist, scale: s)
            }
            let index = h.straightUp(h.indexTip, h.indexPIP, h.indexMCP, t)
            let middle = h.straightUp(h.middleTip, h.middlePIP, h.middleMCP, t)
            let ring = h.straightUp(h.ringTip, h.ringPIP, h.ringMCP, t)
            let little = h.straightUp(h.littleTip, h.littlePIP, h.littleMCP, t)

            // ✋ every finger up, a little spread, thumb out, hand held up.
            if index && middle && ring && little && h.upright
                && Hand.d(h.thumbTip, h.indexMCP) > s * 0.45
                && Hand.d(h.indexTip, h.littleTip) > s * 0.4
                && h.middleTip.y - h.wrist.y > s * 1.3 {
                return Sighting(gesture: .openPalm, wrist: h.wrist, scale: s)
            }
            // ✌️ index and middle up and apart, ring and little folded.
            if index && middle && h.upright
                && h.folded(h.ringTip, h.ringPIP, h.ringMCP, t) && h.folded(h.littleTip, h.littlePIP, h.littleMCP, t)
                && Hand.d(h.indexTip, h.middleTip) > s * 0.3
                && h.thumbTip.y < h.indexTip.y {
                return Sighting(gesture: .peace, wrist: h.wrist, scale: s)
            }
        }

        // ✊ Fingertips are hidden in a fist, so they may be less certain — the knuckles and
        // wrist must be clear, the fist held up, and the thumb not sticking up.
        if let h = Hand(points, aspect: aspect, minConfidence: t.jointConfidence, tipConfidence: 0.1), h.scale > 0.025 {
            let s = h.scale
            let tipsLow = [(h.indexTip, h.indexMCP), (h.middleTip, h.middleMCP),
                           (h.ringTip, h.ringMCP), (h.littleTip, h.littleMCP)].allSatisfy { $0.0.y < $0.1.y + s * 0.25 }
            let thumbDown = h.thumbTip.y < h.indexMCP.y + s * 0.3
            if h.allFolded(t) && tipsLow && thumbDown && h.upright && !h.isThumbsUp(t) {
                return Sighting(gesture: .fist, wrist: h.wrist, scale: s)
            }
        }
        return nil
    }
}
#endif
