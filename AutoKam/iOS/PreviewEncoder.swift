#if os(iOS)
import CoreImage
import ImageIO
import QuartzCore

/// Turns camera frames into small JPEGs (about 15 a second) for the live view on the Mac.
final class PreviewEncoder {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "autokam.preview", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var lastRun: CFTimeInterval = 0

    func encode(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, mirrored: Bool, _ done: @escaping (Data) -> Void) {
        let now = CACurrentMediaTime()
        lock.lock()
        if busy || now - lastRun < 0.066 {
            lock.unlock()
            return
        }
        busy = true
        lastRun = now
        lock.unlock()

        queue.async { [self] in
            var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
            if mirrored { image = image.oriented(.upMirrored) }
            let longest = max(image.extent.width, image.extent.height)
            if longest > 0 {
                let scale = 720 / longest
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let data = context.jpegRepresentation(of: image, colorSpace: space,
                                                     options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.55]) {
                done(data)
            }
            lock.lock(); busy = false; lock.unlock()
        }
    }
}
#endif
