#if os(iOS)
import AVFoundation
import CallKit

/// Owns the capture session. Video frames come out upright (rotation is applied on the
/// connection) so recording, gesture detection and the Mac preview all see the same image.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, CXCallObserverDelegate {
    let session = AVCaptureSession()
    /// Called on the capture queue for every video frame.
    var frameHandler: ((CMSampleBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "autokam.session")
    private let captureQueue = DispatchQueue(label: "autokam.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    private var micInput: AVCaptureDeviceInput?
    private var micRemovedForCall = false // session queue
    private let callObserver = CXCallObserver()
    private var observers: [NSObjectProtocol] = []

    /// A short message about why the camera (or its sound) is paused; nil when all is well.
    /// Called on the main queue.
    var onNotice: ((String?) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                let callNotice = self.micRemovedForCall
                DispatchQueue.main.async { self.onNotice?(callNotice ? Self.callNotice : nil) }
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] _ in
            self?.restartSoon()
        })
        callObserver.setDelegate(self, queue: .main)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private static let callNotice = "On a call — recording video without sound"
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
                    self.micInput = micInput
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
            let active = currentDevice
            DispatchQueue.main.async { completion(active) }
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

    /// Starts the camera again after a pause (e.g. the user tapped the notice).
    func resume() {
        sessionQueue.async { [self] in
            if configured && !session.isRunning { session.startRunning() }
            let callNotice = micRemovedForCall
            DispatchQueue.main.async { self.onNotice?(callNotice ? Self.callNotice : nil) }
        }
    }

    // MARK: - Interruptions

    private func handleInterruption(_ note: Notification) {
        let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
        let reason = AVCaptureSession.InterruptionReason(rawValue: raw)
        switch reason {
        case .audioDeviceInUseByAnotherClient?:
            // A phone/FaceTime call has the microphone. Keep the camera going without it;
            // the mic comes back when the call ends.
            sessionQueue.async { [self] in
                if let mic = micInput, session.inputs.contains(mic) {
                    session.beginConfiguration()
                    session.removeInput(mic)
                    session.commitConfiguration()
                }
                micRemovedForCall = true
                if !session.isRunning { session.startRunning() }
            }
            onNotice?(Self.callNotice)
        case .videoDeviceInUseByAnotherClient?:
            onNotice?("Another app is using the camera — tap to retry")
        case .videoDeviceNotAvailableDueToSystemPressure?:
            onNotice?("Camera paused: iPhone is too hot — tap to retry")
        case .videoDeviceNotAvailableInBackground?:
            break // resumes by itself when the app comes back
        default:
            onNotice?("Camera paused — tap to retry")
        }
    }

    private func restartSoon() {
        sessionQueue.asyncAfter(deadline: .now() + 1) { [self] in
            if configured && !session.isRunning { session.startRunning() }
        }
    }

    private func restoreMicIfPossible() {
        let onCall = callObserver.calls.contains { !$0.hasEnded }
        guard !onCall else { return }
        sessionQueue.async { [self] in
            guard micRemovedForCall, let mic = micInput else { return }
            session.beginConfiguration()
            if session.canAddInput(mic) { session.addInput(mic) }
            session.commitConfiguration()
            micRemovedForCall = false
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async { self.onNotice?(nil) }
        }
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if call.hasEnded {
            // Give the phone call a moment to release the audio hardware.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restoreMicIfPossible() }
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
