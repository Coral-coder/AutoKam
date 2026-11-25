#if os(iOS)
import Foundation
import Vision
import QuartzCore
import CoreVideo

struct GestureProgress: Equatable {
    var gesture: HandGesture
    var progress: Double
}

/// Looks for ✋ / ✊ / 👍 / ✌️ held for `holdDuration` seconds, checking about 20 times a second
/// on the phone itself. Frames must be upright. Callbacks arrive on the main queue.
final class GestureDetector {
    var enabled = true
    /// How long a gesture has to be held. A fist needs a little longer, because a hand
    /// passes through a fist on its way to a thumbs-up.
    var holdDuration: Double = 0.3
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

    func process(_ pixelBuffer: CVPixelBuffer) {
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

        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        queue.async { [self] in
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            var found: Sighting?
            var shown: (point: CGPoint, scale: CGFloat)?
            var handSeen = false
            let aspect = height > 0 ? width / height : 1
            if (try? handler.perform([request])) != nil, let hands = request.results {
                for hand in hands where hand.confidence >= 0.3 {
                    handSeen = true
                    if let sighting = Self.classify(hand, aspect: aspect) {
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
        gesture == .fist ? holdDuration * 1.3 : holdDuration
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
        if sighting.gesture != current || anchor.map({ Hand.d($0, sighting.wrist) > sighting.scale * 0.45 }) ?? true {
            current = sighting.gesture
            anchor = sighting.wrist
            since = now
            firstSeen = Date()
            frames = 0
        }
        frames += 1
        let progress = min(1, (now - since) / hold(for: sighting.gesture))
        if progress >= 1 && frames >= 6 {
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
        func straightUp(_ tip: CGPoint, _ pip: CGPoint, _ mcp: CGPoint) -> Bool {
            Self.d(wrist, tip) > Self.d(wrist, pip) * 1.15
                && Self.d(tip, mcp) > scale * 0.7
                && tip.y - mcp.y > scale * 0.6
        }
        /// Folded right down into the palm.
        func folded(_ tip: CGPoint, _ pip: CGPoint, _ mcp: CGPoint) -> Bool {
            Self.d(wrist, tip) < Self.d(wrist, pip) && Self.d(tip, mcp) < scale * 0.65
        }
        var allFolded: Bool {
            folded(indexTip, indexPIP, indexMCP) && folded(middleTip, middlePIP, middleMCP)
                && folded(ringTip, ringPIP, ringMCP) && folded(littleTip, littlePIP, littleMCP)
        }
        /// Hand held up: knuckles well above the wrist.
        var upright: Bool { middleMCP.y - wrist.y > scale * 0.7 }

        var isThumbsUp: Bool {
            guard allFolded else { return false }
            let dy = thumbTip.y - thumbMP.y
            let dx = abs(thumbTip.x - thumbMP.x)
            let others = [indexTip, middleTip, ringTip, littleTip, indexPIP, middlePIP, indexMCP, middleMCP, wrist]
            return Self.d(thumbTip, thumbMP) > scale * 0.45
                && dy > scale * 0.5 && dy > dx * 2
                && thumbTip.y > thumbIP.y && thumbIP.y > thumbMP.y
                && others.allSatisfy { thumbTip.y > $0.y + scale * 0.25 }
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

    private static func classify(_ observation: VNHumanHandPoseObservation, aspect: CGFloat) -> Sighting? {
        guard observation.confidence >= 0.5, let points = try? observation.recognizedPoints(.all) else { return nil }

        if let h = Hand(points, aspect: aspect, minConfidence: 0.5, tipConfidence: 0.5), h.scale > 0.035 {
            let s = h.scale
            if h.isThumbsUp {
                return Sighting(gesture: .thumbsUp, wrist: h.wrist, scale: s)
            }
            let index = h.straightUp(h.indexTip, h.indexPIP, h.indexMCP)
            let middle = h.straightUp(h.middleTip, h.middlePIP, h.middleMCP)
            let ring = h.straightUp(h.ringTip, h.ringPIP, h.ringMCP)
            let little = h.straightUp(h.littleTip, h.littlePIP, h.littleMCP)

            // ✋ every finger straight up, spread, thumb out, hand held up.
            if index && middle && ring && little && h.upright
                && Hand.d(h.thumbTip, h.indexMCP) > s * 0.6
                && Hand.d(h.indexTip, h.littleTip) > s * 0.6
                && h.middleTip.y - h.wrist.y > s * 1.6 {
                return Sighting(gesture: .openPalm, wrist: h.wrist, scale: s)
            }
            // ✌️ index and middle up and apart, ring and little folded, thumb not up.
            if index && middle && h.upright
                && h.folded(h.ringTip, h.ringPIP, h.ringMCP) && h.folded(h.littleTip, h.littlePIP, h.littleMCP)
                && Hand.d(h.indexTip, h.middleTip) > s * 0.4
                && h.thumbTip.y < h.indexPIP.y {
                return Sighting(gesture: .peace, wrist: h.wrist, scale: s)
            }
        }

        // ✊ Fingertips are hidden in a fist, so they may be less certain — but the knuckles
        // and wrist must be clear, the fist held up with knuckles level across the top, and
        // the thumb tucked in.
        if let h = Hand(points, aspect: aspect, minConfidence: 0.5, tipConfidence: 0.2), h.scale > 0.035 {
            let s = h.scale
            let tipsUnderKnuckles = [(h.indexTip, h.indexPIP), (h.middleTip, h.middlePIP),
                                     (h.ringTip, h.ringPIP), (h.littleTip, h.littlePIP)].allSatisfy { $0.0.y < $0.1.y }
            let knucklesLevel = abs(h.indexMCP.y - h.littleMCP.y) < s * 0.5
            let thumbTucked = h.thumbTip.y < h.indexPIP.y + s * 0.2 && Hand.d(h.thumbTip, h.middlePIP) < s * 0.9
            if h.allFolded && tipsUnderKnuckles && knucklesLevel && thumbTucked && h.upright && !h.isThumbsUp {
                return Sighting(gesture: .fist, wrist: h.wrist, scale: s)
            }
        }
        return nil
    }
}
#endif
