#if os(iOS)
import Foundation
import Vision
import QuartzCore
import CoreVideo

struct GestureProgress: Equatable {
    var gesture: HandGesture
    var progress: Double
}

/// Looks for ✋ / 👍 / ✌️ held steady for `holdDuration` seconds (about 10 checks a second).
/// Frames must be upright. Callbacks arrive on the main queue.
final class GestureDetector {
    var enabled = true
    var holdDuration: Double = 0.7
    var onProgress: ((GestureProgress?) -> Void)?
    /// The gesture and when it first appeared (used to trim it off a kept take).
    var onGesture: ((HandGesture, Date) -> Void)?

    private let queue = DispatchQueue(label: "autokam.vision", qos: .userInitiated)
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
        if busy || now - lastRun < 0.1 {
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

    private func update(_ gesture: HandGesture?, now: CFTimeInterval) {
        if now < cooldownUntil {
            report(nil)
            return
        }
        if gesture == nil, current != nil, misses < 2 {
            misses += 1 // tolerate a dropped detection or two
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
        let progress = min(1, (now - since) / holdDuration)
        if progress >= 1 {
            let seenAt = firstSeen
            current = nil
            cooldownUntil = now + 1.5
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

    static func classify(_ hand: VNHumanHandPoseObservation, aspect: CGFloat) -> HandGesture? {
        guard let points = try? hand.recognizedPoints(.all) else { return nil }
        func p(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let point = points[joint], point.confidence > 0.3 else { return nil }
            // Normalised coordinates, origin bottom-left; scale x so distances are square.
            return CGPoint(x: point.location.x * aspect, y: point.location.y)
        }
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        guard let wrist = p(.wrist), let middleMCP = p(.middleMCP), let indexMCP = p(.indexMCP),
              let thumbTip = p(.thumbTip), let thumbIP = p(.thumbIP), let thumbMP = p(.thumbMP),
              let indexTip = p(.indexTip), let indexPIP = p(.indexPIP),
              let middleTip = p(.middleTip), let middlePIP = p(.middlePIP),
              let ringTip = p(.ringTip), let ringPIP = p(.ringPIP), let ringMCP = p(.ringMCP),
              let littleTip = p(.littleTip), let littlePIP = p(.littlePIP), let littleMCP = p(.littleMCP)
        else { return nil }

        let scale = d(wrist, middleMCP)
        guard scale > 0.03 else { return nil } // hand too small to read reliably

        func extended(_ tip: CGPoint, _ pip: CGPoint, _ mcp: CGPoint) -> Bool {
            d(wrist, tip) > d(wrist, pip) * 1.12 && d(tip, mcp) > scale * 0.55
        }
        func curled(_ tip: CGPoint, _ pip: CGPoint) -> Bool {
            d(wrist, tip) < d(wrist, pip) * 1.05
        }

        let indexOut = extended(indexTip, indexPIP, indexMCP)
        let middleOut = extended(middleTip, middlePIP, middleMCP)
        let ringOut = extended(ringTip, ringPIP, ringMCP)
        let littleOut = extended(littleTip, littlePIP, littleMCP)
        let indexIn = curled(indexTip, indexPIP)
        let middleIn = curled(middleTip, middlePIP)
        let ringIn = curled(ringTip, ringPIP)
        let littleIn = curled(littleTip, littlePIP)
        let thumbOut = d(thumbTip, indexMCP) > scale * 0.5 && d(wrist, thumbTip) > d(wrist, thumbMP) * 1.1

        // 👍 fingers in a fist, thumb pointing up and above everything else.
        if indexIn && middleIn && ringIn && littleIn && thumbOut {
            let dy = thumbTip.y - thumbMP.y
            let dx = abs(thumbTip.x - thumbMP.x)
            let highest = [indexTip, middleTip, ringTip, littleTip, indexMCP, wrist].allSatisfy { thumbTip.y > $0.y }
            if dy > scale * 0.45 && dy > dx && thumbTip.y > thumbIP.y && highest {
                return .thumbsUp
            }
        }

        // ✋ open hand, fingers up.
        if indexOut && middleOut && ringOut && littleOut && thumbOut && middleTip.y > wrist.y + scale * 0.9 {
            return .openPalm
        }

        // ✌️ index and middle up and apart, ring and little folded.
        if indexOut && middleOut && ringIn && littleIn
            && indexTip.y > wrist.y + scale * 0.9 && middleTip.y > wrist.y + scale * 0.9
            && d(indexTip, middleTip) > scale * 0.3 {
            return .peace
        }
        return nil
    }
}
#endif
