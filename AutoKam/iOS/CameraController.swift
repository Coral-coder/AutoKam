#if os(iOS)
import AVFoundation
import ImageIO
import CallKit

/// Owns the capture session. Video frames come out upright (rotation is applied on the
/// connection) so recording, gesture detection and the Mac preview all see the same image.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, CXCallObserverDelegate, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    /// Called on the capture queue for every video frame.
    /// Frames come straight off the sensor (not rotated, which is too costly at 4K60);
    /// the orientation says how to turn them upright.
    var frameHandler: ((CMSampleBuffer, CGImagePropertyOrientation) -> Void)?

    /// The mode the camera is actually running (it may not reach what was asked for).
    struct ActiveMode: Equatable {
        var width: Int
        var height: Int
        var fps: Int
        var label: String {
            let name = width >= 3840 ? "4K" : height >= 1080 || width >= 1920 ? "1080p" : "\(min(width, height))p"
            return "\(name) \(fps)"
        }
    }

    private let sessionQueue = DispatchQueue(label: "autokam.session")
    private let captureQueue = DispatchQueue(label: "autokam.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    private var micInput: AVCaptureDeviceInput?
    private let metadataOutput = AVCaptureMetadataOutput()
    private var focusObservation: NSKeyValueObservation?
    /// Faces the camera sees (for the focus target). Main queue.
    var onFaces: (([AVMetadataObject]) -> Void)?
    /// Whether autofocus is moving right now. Main queue.
    var onFocusAdjusting: ((Bool) -> Void)?
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

    func configure(front: Bool, uhd: Bool, fps: Int, completion: @escaping (AVCaptureDevice?, ActiveMode?) -> Void) {
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
                if session.canAddOutput(metadataOutput) {
                    session.addOutput(metadataOutput)
                    metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
                }
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
            if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                metadataOutput.metadataObjectTypes = [.face]
            }
            if let device = currentDevice {
                configureAutoFocus(device, at: nil)
                focusObservation = device.observe(\.isAdjustingFocus, options: [.initial, .new]) { [weak self] device, _ in
                    let adjusting = device.isAdjustingFocus
                    DispatchQueue.main.async { self?.onFocusAdjusting?(adjusting) }
                }
            }

            var mode: ActiveMode?
            if let device = currentDevice {
                mode = selectFormat(device, uhd: uhd, fps: fps)
            }
            if mode == nil {
                session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
            }

            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
                // Frames stay as the sensor delivers them; recordings carry the rotation.
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0
                }
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            // Formats can reset the frame rate when the session commits; set it again.
            if let device = currentDevice, let mode { applyFrameRate(device, fps: mode.fps) }
            let active = currentDevice
            DispatchQueue.main.async { completion(active, mode) }
        }
    }

    /// Picks the camera format for 4K or 1080p at the wanted frame rate (falling back to the
    /// best the camera can do) and returns what it's running.
    private func selectFormat(_ device: AVCaptureDevice, uhd: Bool, fps: Int) -> ActiveMode? {
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(f.formatDescription) }
        func maxRate(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        func usable(_ f: AVCaptureDevice.Format) -> Bool {
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        func best(width: Int32) -> AVCaptureDevice.Format? {
            let candidates = device.formats.filter { usable($0) && dims($0).width == width && dims($0).height == width * 9 / 16 }
            let fast = candidates.filter { maxRate($0) >= Double(fps) - 0.5 }
            let pool = fast.isEmpty ? candidates : fast
            // Prefer video-range 8-bit, unbinned, highest frame rate.
            return pool.max { a, b in
                func score(_ f: AVCaptureDevice.Format) -> Double {
                    var s = min(maxRate(f), Double(fps)) * 10
                    if CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { s += 2 }
                    if !f.isVideoBinned { s += 1 }
                    return s
                }
                return score(a) < score(b)
            }
        }
        guard let format = (uhd ? best(width: 3840) : nil) ?? best(width: 1920) else { return nil }
        guard (try? device.lockForConfiguration()) != nil else { return nil }
        device.activeFormat = format // also switches the session to input-priority
        device.unlockForConfiguration()
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: subtype]
        let rate = Int(min(maxRate(format), Double(fps)).rounded())
        applyFrameRate(device, fps: rate)
        let d = dims(format)
        return ActiveMode(width: Int(d.width), height: Int(d.height), fps: rate)
    }

    private func applyFrameRate(_ device: AVCaptureDevice, fps: Int) {
        guard fps > 0, (try? device.lockForConfiguration()) != nil else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= Double(fps) - 0.5 && $0.minFrameRate <= Double(fps) + 0.5 }) {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        device.unlockForConfiguration()
    }

    /// Clockwise degrees that turn sensor frames upright (0, 90, 180 or 270). Recordings and
    /// gesture detection use it; it's only changed between takes.
    private(set) var rotation: CGFloat = 90

    func setRotation(_ angle: CGFloat) {
        rotation = angle
    }

    static func orientation(for angle: CGFloat) -> CGImagePropertyOrientation {
        switch Int(angle) {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    // MARK: - Focus

    /// Focus (and expose) on a point in device coordinates (0–1); nil goes back to automatic,
    /// which follows faces.
    func focus(at point: CGPoint?) {
        sessionQueue.async { [self] in
            guard let device = videoInput?.device else { return }
            configureAutoFocus(device, at: point)
        }
    }

    private func configureAutoFocus(_ device: AVCaptureDevice, at point: CGPoint?) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        let target = point ?? CGPoint(x: 0.5, y: 0.5)
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = target }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        } else if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
        }
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = target }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        // Automatic focus follows faces; a tapped point overrides that.
        device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = point == nil
        device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = point == nil
        if point != nil {
            device.isFaceDrivenAutoFocusEnabled = false
            device.isFaceDrivenAutoExposureEnabled = false
        }
        device.unlockForConfiguration()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        onFaces?(metadataObjects)
    }

    /// Size of the (upright) frames, for converting positions found in them.
    private var frameSize = CGSize(width: 1080, height: 1920)

    /// A point in the upright frame (0–1, origin top-left) as a focus point of interest.
    func devicePoint(forFramePoint upright: CGPoint) -> CGPoint {
        // Undo the rotation to get back to the sensor frame.
        let u = upright.x, v = upright.y
        let point: CGPoint
        switch Int(rotation) {
        case 90: point = CGPoint(x: v, y: 1 - u)
        case 180: point = CGPoint(x: 1 - u, y: 1 - v)
        case 270: point = CGPoint(x: 1 - v, y: u)
        default: point = CGPoint(x: u, y: v)
        }
        let size = frameSize
        let rect = CGRect(x: point.x * size.width - 2, y: point.y * size.height - 2, width: 4, height: 4)
        let converted = videoOutput.metadataOutputRectConverted(fromOutputRect: rect)
        return CGPoint(x: converted.midX, y: converted.midY)
    }

    // MARK: - Sound

    struct ChannelLevel {
        var average: Float // dBFS
        var peak: Float    // dBFS
    }

    /// Current microphone levels, one per channel. Main thread.
    func audioLevels() -> [ChannelLevel] {
        guard let connection = audioOutput.connection(with: .audio) else { return [] }
        return connection.audioChannels.map { ChannelLevel(average: $0.averagePowerLevel, peak: $0.peakHoldLevel) }
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

    /// Starts writing a take to `fileURL` on the phone.
    func startTake(fileURL: URL, config: TakeWriter.Config) {
        captureQueue.async { [self] in
            writer = TakeWriter(fileURL: fileURL, config: config)
        }
    }

    /// Ends the take. Calls back on a background thread once the file is complete.
    func stopTake(_ completion: @escaping (TakeWriter.Result) -> Void) {
        captureQueue.async { [self] in
            guard let current = writer else {
                completion(TakeWriter.Result(bytes: 0, duration: 0, ok: false, audioBuffers: 0))
                return
            }
            writer = nil
            current.finish(completion)
        }
    }

    // MARK: - Sample buffer delegate (video and audio share this method)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let dims = CMVideoFormatDescriptionGetDimensions(format)
                frameSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
            }
            writer?.appendVideo(sampleBuffer)
            frameHandler?(sampleBuffer, Self.orientation(for: rotation))
        } else {
            writer?.appendAudio(sampleBuffer)
        }
    }
}
#endif
