#if os(iOS)
import AVFoundation

/// Owns the capture session. Video frames come out upright (rotation is applied on the
/// connection) so recording, gesture detection and the Mac preview all see the same image.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    /// Called on the capture queue for every video frame.
    var frameHandler: ((CMSampleBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "autokam.session")
    private let captureQueue = DispatchQueue(label: "autokam.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    private var writer: TakeWriter? // capture queue only

    private(set) var currentDevice: AVCaptureDevice?

    func configure(front: Bool, uhd: Bool, completion: @escaping (AVCaptureDevice?) -> Void) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            if !configured {
                configured = true
                if let mic = AVCaptureDevice.default(for: .audio),
                   let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
                    session.addInput(micInput)
                }
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                videoOutput.alwaysDiscardsLateVideoFrames = false
                videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
                if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
                audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
                if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            }

            if let old = videoInput {
                session.removeInput(old)
                videoInput = nil
            }
            let position: AVCaptureDevice.Position = front ? .front : .back
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video)
            if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
            currentDevice = videoInput?.device

            if uhd && session.canSetSessionPreset(.hd4K3840x2160) {
                session.sessionPreset = .hd4K3840x2160
            } else if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            } else {
                session.sessionPreset = .high
            }

            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            let device = currentDevice
            DispatchQueue.main.async { completion(device) }
        }
    }

    func setRotation(_ angle: CGFloat) {
        sessionQueue.async { [self] in
            guard let connection = videoOutput.connection(with: .video),
                  connection.isVideoRotationAngleSupported(angle),
                  connection.videoRotationAngle != angle else { return }
            connection.videoRotationAngle = angle
        }
    }

    func stopRunning() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func startRunning() {
        sessionQueue.async { [self] in
            if configured && !session.isRunning { session.startRunning() }
        }
    }

    /// Starts writing a take. `onSegment` is called on a writer thread with each fMP4 segment.
    func startTake(fileURL: URL, config: TakeWriter.Config, onSegment: @escaping (Data, Int64) -> Void) {
        captureQueue.async { [self] in
            writer = TakeWriter(fileURL: fileURL, config: config, onSegment: onSegment)
        }
    }

    /// Ends the take. Calls back (on a background thread) with (bytes, duration, success).
    func stopTake(_ completion: @escaping (Int64, Double, Bool) -> Void) {
        captureQueue.async { [self] in
            guard let current = writer else {
                completion(0, 0, false)
                return
            }
            writer = nil
            current.finish(completion)
        }
    }

    // MARK: - Sample buffer delegate (video and audio share this method)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            writer?.appendVideo(sampleBuffer)
            frameHandler?(sampleBuffer)
        } else {
            writer?.appendAudio(sampleBuffer)
        }
    }
}
#endif
