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
            var found: HandGesture?
            if (try? handler.perform([request])) != nil, let hands = request.results {
                let aspect = height > 0 ? width / height : 1
                for hand in hands {
                    if let gesture = Self.classify(hand, aspect: aspect) {
                        found = gesture
                        break
                    }
                }
            }
            update(found, now: CACurrentMediaTime())
            lock.lock(); busy = false; lock.unlock()
        }
    }

    private func hold(for gesture: HandGesture) -> Double {
        gesture == .fist ? holdDuration * 1.4 + 0.05 : holdDuration
    }

    private func update(_ gesture: HandGesture?, now: CFTimeInterval) {
        if now < cooldownUntil {
            report(nil)
            return
        }
        if gesture == nil, current != nil, misses < 1 {
            misses += 1 // tolerate one dropped detection
            return
        }
        misses = 0
        guard let gesture else {
            current = nil
            report(nil)
            return
        }
        if gesture != current {
            current = gesture
            since = now
            firstSeen = Date()
        }
        let progress = min(1, (now - since) / hold(for: gesture))
        if progress >= 1 {
            let seenAt = firstSeen
            current = nil
            cooldownUntil = now + 1.2
            report(nil)
            DispatchQueue.main.async { self.onGesture?(gesture, seenAt) }
        } else {
            report(GestureProgress(gesture: gesture, progress: progress))
        }
    }

    private func report(_ progress: GestureProgress?) {
        DispatchQueue.main.async { self.onProgress?(progress) }
    }

    // MARK: - Classification

    /// Hand joints in square-ish coordinates (x scaled by the aspect ratio), y pointing up.
    private struct Hand {
        var wrist, thumbTip, thumbIP, thumbMP: CGPoint
        var indexTip, indexPIP, indexMCP: CGPoint
        var middleTip, middlePIP, middleMCP: CGPoint
        var ringTip, ringPIP, ringMCP: CGPoint
        var littleTip, littlePIP, littleMCP: CGPoint

        init?(_ points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint], aspect: CGFloat, minConfidence: Float) {
            func p(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
                guard let point = points[joint], point.confidence > minConfidence else { return nil }
                return CGPoint(x: point.location.x * aspect, y: point.location.y)
            }
            guard let wrist = p(.wrist), let thumbTip = p(.thumbTip), let thumbIP = p(.thumbIP), let thumbMP = p(.thumbMP),
                  let indexTip = p(.indexTip), let indexPIP = p(.indexPIP), let indexMCP = p(.indexMCP),
                  let middleTip = p(.middleTip), let middlePIP = p(.middlePIP), let middleMCP = p(.middleMCP),
                  let ringTip = p(.ringTip), let ringPIP = p(.ringPIP), let ringMCP = p(.ringMCP),
                  let littleTip = p(.littleTip), let littlePIP = p(.littlePIP), let littleMCP = p(.littleMCP)
            else { return nil }
            self.wrist = wrist; self.thumbTip = thumbTip; self.thumbIP = thumbIP; self.thumbMP = thumbMP
            self.indexTip = indexTip; self.indexPIP = indexPIP; self.indexMCP = indexMCP
            self.middleTip = middleTip; self.middlePIP = middlePIP; self.middleMCP = middleMCP
            self.ringTip = ringTip; self.ringPIP = ringPIP; self.ringMCP = ringMCP
            self.littleTip = littleTip; self.littlePIP = littlePIP; self.littleMCP = littleMCP
        }

        static func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        var scale: CGFloat { Self.d(wrist, middleMCP) }

        func extended(_ tip: CGPoint, _ pip: CGPoint, _ mcp: CGPoint) -> Bool {
            Self.d(wrist, tip) > Self.d(wrist, pip) * 1.12 && Self.d(tip, mcp) > scale * 0.55
        }
        func curled(_ tip: CGPoint, _ pip: CGPoint) -> Bool {
            Self.d(wrist, tip) < Self.d(wrist, pip) * 1.05
        }
        var fingersCurled: Bool {
            curled(indexTip, indexPIP) && curled(middleTip, middlePIP) && curled(ringTip, ringPIP) && curled(littleTip, littlePIP)
        }
        var thumbOut: Bool {
            Self.d(thumbTip, indexMCP) > scale * 0.5 && Self.d(wrist, thumbTip) > Self.d(wrist, thumbMP) * 1.1
        }
        var isThumbsUp: Bool {
            guard fingersCurled && thumbOut else { return false }
            let dy = thumbTip.y - thumbMP.y
            let dx = abs(thumbTip.x - thumbMP.x)
            let highest = [indexTip, middleTip, ringTip, littleTip, indexMCP, wrist].allSatisfy { thumbTip.y > $0.y }
            return dy > scale * 0.45 && dy > dx && thumbTip.y > thumbIP.y && highest
        }
    }

    static func classify(_ observation: VNHumanHandPoseObservation, aspect: CGFloat) -> HandGesture? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }

        if let h = Hand(points, aspect: aspect, minConfidence: 0.3), h.scale > 0.03 {
            let s = h.scale
            // 👍 fingers in a fist, thumb pointing up and above everything else.
            if h.isThumbsUp { return .thumbsUp }

            let indexOut = h.extended(h.indexTip, h.indexPIP, h.indexMCP)
            let middleOut = h.extended(h.middleTip, h.middlePIP, h.middleMCP)
            let ringOut = h.extended(h.ringTip, h.ringPIP, h.ringMCP)
            let littleOut = h.extended(h.littleTip, h.littlePIP, h.littleMCP)

            // ✋ open hand, fingers up.
            if indexOut && middleOut && ringOut && littleOut && h.thumbOut && h.middleTip.y > h.wrist.y + s * 0.9 {
                return .openPalm
            }
            // ✌️ index and middle up and apart, ring and little folded.
            if indexOut && middleOut && h.curled(h.ringTip, h.ringPIP) && h.curled(h.littleTip, h.littlePIP)
                && h.indexTip.y > h.wrist.y + s * 0.9 && h.middleTip.y > h.wrist.y + s * 0.9
                && Hand.d(h.indexTip, h.middleTip) > s * 0.3 {
                return .peace
            }
        }

        // ✊ In a fist most fingertips are hidden, so accept low-confidence joints here.
        if let h = Hand(points, aspect: aspect, minConfidence: 0.05), h.scale > 0.03 {
            let s = h.scale
            let thumbTucked = h.thumbTip.y - h.indexMCP.y < s * 0.35 && Hand.d(h.thumbTip, h.indexMCP) < s * 0.85
            let raised = h.middleMCP.y > h.wrist.y + s * 0.5
            if h.fingersCurled && thumbTucked && raised && !h.isThumbsUp {
                return .fist
            }
        }
        return nil
    }
}
#endif
