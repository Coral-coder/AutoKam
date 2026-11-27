#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit
import ImageIO
import AudioToolbox

enum GestureSpeed: String, Codable, CaseIterable, Identifiable {
    case quick, normal, careful
    var id: String { rawValue }
    var label: String {
        switch self {
        case .quick: return "High"
        case .normal: return "Medium"
        case .careful: return "Low"
        }
    }
    /// How loose the shapes may be and how long to hold them.
    var tuning: GestureTuning {
        switch self {
        case .quick: return .high
        case .normal: return .medium
        case .careful: return .low
        }
    }
}

enum VideoQuality: String, Codable, CaseIterable, Identifiable {
    case standard, high, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Standard (smaller files)"
        case .high: return "High"
        case .max: return "Maximum"
        }
    }
    /// Average video bitrate for a mode, in bits per second.
    func bitrate(width: Int, fps: Int, hevc: Bool) -> Int {
        let uhd = width >= 3840
        let base: Double // HEVC at 30 fps, Mbit/s
        switch self {
        case .standard: base = uhd ? 28 : 10
        case .high: base = uhd ? 40 : 16
        case .max: base = uhd ? 65 : 25
        }
        let rate = fps > 30 ? 1.5 : 1.0
        let codec = hevc ? 1.0 : 1.6
        return Int(base * rate * codec * 1_000_000)
    }
}

struct CaptureSettings: Codable, Equatable {
    var gesturesEnabled = true
    var countdown = 3
    var uhd = true
    var fps = 60
    var quality = VideoQuality.high
    var hevc = true
    var trimGesture = true
    var deleteAfterTransfer = true
    var frontCamera = true
    var sendPreview = true
    var gestureSpeed = GestureSpeed.normal
    /// Gestures switched off (raw values).
    var disabledGestures: [String] = []
    var countInBeeps = true
    var warnNoExternalMic = true
    var showLevel = true
    var focusOnShownObjects = true
    var gestureDebug = false

    init() {}

    // Settings saved by an older version are missing the newer keys; keep what's there.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptureSettings()
        gesturesEnabled = try c.decodeIfPresent(Bool.self, forKey: .gesturesEnabled) ?? d.gesturesEnabled
        countdown = try c.decodeIfPresent(Int.self, forKey: .countdown) ?? d.countdown
        uhd = try c.decodeIfPresent(Bool.self, forKey: .uhd) ?? d.uhd
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        quality = try c.decodeIfPresent(VideoQuality.self, forKey: .quality) ?? d.quality
        // Before the quality settings existed everything ran at 1080p 30; start at 4K 60.
        if try c.decodeIfPresent(Int.self, forKey: .fps) == nil { uhd = true }
        hevc = try c.decodeIfPresent(Bool.self, forKey: .hevc) ?? d.hevc
        trimGesture = try c.decodeIfPresent(Bool.self, forKey: .trimGesture) ?? d.trimGesture
        deleteAfterTransfer = try c.decodeIfPresent(Bool.self, forKey: .deleteAfterTransfer) ?? d.deleteAfterTransfer
        frontCamera = try c.decodeIfPresent(Bool.self, forKey: .frontCamera) ?? d.frontCamera
        sendPreview = try c.decodeIfPresent(Bool.self, forKey: .sendPreview) ?? d.sendPreview
        gestureSpeed = try c.decodeIfPresent(GestureSpeed.self, forKey: .gestureSpeed) ?? d.gestureSpeed
        disabledGestures = try c.decodeIfPresent([String].self, forKey: .disabledGestures) ?? d.disabledGestures
        // Builds before the stricter recognizer defaulted to Quick, which fired far too easily.
        if try c.decodeIfPresent([String].self, forKey: .disabledGestures) == nil, gestureSpeed == .quick {
            gestureSpeed = .normal
        }
        countInBeeps = try c.decodeIfPresent(Bool.self, forKey: .countInBeeps) ?? d.countInBeeps
        warnNoExternalMic = try c.decodeIfPresent(Bool.self, forKey: .warnNoExternalMic) ?? d.warnNoExternalMic
        showLevel = try c.decodeIfPresent(Bool.self, forKey: .showLevel) ?? d.showLevel
        focusOnShownObjects = try c.decodeIfPresent(Bool.self, forKey: .focusOnShownObjects) ?? d.focusOnShownObjects
        gestureDebug = try c.decodeIfPresent(Bool.self, forKey: .gestureDebug) ?? d.gestureDebug
    }
}

/// Which microphone is in use and how loud it is. Updated ~15 times a second, kept apart
/// from the main model so only the meter redraws.
final class AudioMeter: ObservableObject {
    struct Channel: Equatable {
        var average: Float
        var peak: Float
    }

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var micName = "iPhone mic"
    @Published private(set) var isExternal = false
    /// Last time the mic picked up anything above a dead-quiet level.
    private(set) var lastSoundAt = Date()

    var isStereo: Bool { channels.count >= 2 }

    func update(_ levels: [CameraController.ChannelLevel]) {
        let new = levels.prefix(2).map { Channel(average: $0.average, peak: $0.peak) }
        if new.contains(where: { $0.peak > -65 }) { lastSoundAt = Date() }
        if new != channels { channels = new }
    }

    func updateRoute() {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        let name: String
        let external: Bool
        if let input = inputs.first {
            external = input.portType != .builtInMic
            name = external ? input.portName : "iPhone mic"
        } else {
            external = false
            name = "No mic"
        }
        if name != micName { micName = name }
        if external != isExternal { isExternal = external }
    }

    func resetSilenceTimer() { lastSoundAt = Date() }
}

/// Where the camera is focusing, in preview (screen) coordinates.
final class FocusTracker: ObservableObject {
    enum Mode { case auto, face, manual, object }
    @Published private(set) var rect: CGRect?
    @Published private(set) var mode: Mode = .auto
    @Published var adjusting = false

    func set(_ newRect: CGRect, mode newMode: Mode) {
        if newMode != mode { mode = newMode }
        if let rect, abs(rect.midX - newRect.midX) < 4, abs(rect.midY - newRect.midY) < 4,
           abs(rect.width - newRect.width) < 6 { return }
        rect = newRect
    }
}

struct RecognizedGesture: Equatable, Identifiable {
    let id = UUID()
    var gesture: HandGesture
    var action: String
}

enum OrientationMode: String, CaseIterable, Identifiable {
    case auto, portrait, landscape
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Follow phone"
        case .portrait: return "Portrait 9:16"
        case .landscape: return "Landscape 16:9"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: return "Auto"
        case .portrait: return "9:16"
        case .landscape: return "16:9"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "arrow.triangle.2.circlepath"
        case .portrait: return "rectangle.portrait"
        case .landscape: return "rectangle"
        }
    }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .auto: return .allButUpsideDown
        case .portrait: return .portrait
        case .landscape: return .landscape
        }
    }
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var color: Color
}

final class CameraAppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case recording
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { sendStatus() } }
    }
    @Published private(set) var recordingStart: Date?
    @Published private(set) var currentNumber = 1
    @Published private(set) var sessionName: String
    @Published var settings: CaptureSettings {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published private(set) var gestureProgress: GestureProgress?
    /// What the phone sees per finger (Settings → Gestures → Show what it sees).
    @Published private(set) var gestureDebugText: String?
    @Published private(set) var toast: Toast?
    @Published private(set) var flashColor: Color?
    @Published private(set) var cameraReady = false
    /// What the camera is really running, e.g. "4K 60".
    @Published private(set) var activeMode: CameraController.ActiveMode?
    @Published private(set) var accessDenied = false
    /// Why the camera or its sound is paused (e.g. on a phone call); nil when all is well.
    @Published private(set) var cameraNotice: String?
    /// Portrait or landscape video. The screen rotates to match.
    @Published var orientationMode: OrientationMode {
        didSet {
            UserDefaults.standard.set(orientationMode.rawValue, forKey: "orientationMode")
            OrientationLock.apply(orientationMode.mask)
            updateCaptureAngle(rawCaptureAngle)
        }
    }
    /// Whether the next (or current) take is landscape.
    @Published private(set) var recordsLandscape = false
    /// The part of the video being recorded, and the try at it (the next one when idle).
    @Published private(set) var segment = 1
    @Published private(set) var segmentTake = 1
    /// Pops up big on screen for a moment when a gesture fires.
    @Published private(set) var recognized: RecognizedGesture?
    /// A small, non-blocking sound warning (no external mic, or no sound while recording).
    @Published private(set) var audioWarning: String?
    @Published var showWalkthrough = !UserDefaults.standard.bool(forKey: "walkthroughSeen")

    let meter = AudioMeter()
    let focus = FocusTracker()
    let level = LevelMeter()

    let camera = CameraController()
    let link = PhoneLink()
    let store = TakeStore()
    private let gestures = GestureDetector()
    private let previewEncoder = PreviewEncoder()

    private var currentTake: TakeInfo?
    private var lastTakeID: UUID?
    private var nextNumber: Int {
        didSet {
            UserDefaults.standard.set(nextNumber, forKey: "nextTakeNumber")
            if phase != .recording { currentNumber = nextNumber }
        }
    }
    private var countdownTimer: Timer?
    private var statusTimer: Timer?
    private var uploading = Set<UUID>()
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservers: [NSKeyValueObservation] = []
    private var captureAngle: CGFloat = 90
    private var rawCaptureAngle: CGFloat = 90
    private var toastWork: DispatchWorkItem?
    private var recognizedWork: DispatchWorkItem?
    private var meterTimer: Timer?
    private var manualFocusPoint: CGPoint?
    /// Focus point of something she's holding up to the camera.
    private var objectFocusPoint: CGPoint?
    private var lastFaceAt = Date.distantPast
    private var snoozedWarning: (text: String, until: Date)?
    private var lastGestureForMac: (HandGesture, Date)?
    private var routeObserver: NSObjectProtocol?
    private var takeHadSoundWarning = false
    private var started = false

    // Read on the capture queue.
    private var previewEnabled = true
    private var previewMirrored = true

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "settings"),
           let saved = try? JSONDecoder().decode(CaptureSettings.self, from: data) {
            settings = saved
        } else {
            settings = CaptureSettings()
        }
        sessionName = defaults.string(forKey: "sessionName") ?? ""
        orientationMode = OrientationMode(rawValue: defaults.string(forKey: "orientationMode") ?? "") ?? .auto
        nextNumber = max(1, defaults.integer(forKey: "nextTakeNumber"))
        currentNumber = nextNumber
        segment = max(1, defaults.integer(forKey: "segment"))
        segmentTake = max(1, defaults.integer(forKey: "segmentTake"))
        previewEnabled = settings.sendPreview
        previewMirrored = settings.frontCamera
        wire()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        OrientationLock.apply(orientationMode.mask)
        requestAccess { [weak self] granted in
            guard let self else { return }
            if granted {
                self.configureCamera()
            } else {
                self.accessDenied = true
            }
        }
        link.start()
        // Count-in beeps play while the microphone is live.
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
        meter.updateRoute()
        level.start()
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.routeChanged()
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkWarnings()
            self?.refreshAutoFocusTarget()
            self?.sendStatus()
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.meter.update(self.camera.audioLevels())
        }
    }

    func isGestureOn(_ gesture: HandGesture) -> Bool {
        !settings.disabledGestures.contains(gesture.rawValue)
    }

    func setGesture(_ gesture: HandGesture, on: Bool) {
        settings.disabledGestures.removeAll { $0 == gesture.rawValue }
        if !on { settings.disabledGestures.append(gesture.rawValue) }
    }

    /// One tap on the gesture strip pauses or resumes gestures.
    func toggleGestures() {
        settings.gesturesEnabled.toggle()
        showToast(settings.gesturesEnabled ? "Gestures on" : "Gestures paused", color: .white)
    }

    func walkthroughDone() {
        UserDefaults.standard.set(true, forKey: "walkthroughSeen")
        showWalkthrough = false
    }

    func enteredBackground() {
        cancelCountdown()
        if phase == .recording { stopTake(good: false) }
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        setUpRotation(camera.currentDevice)
    }

    // MARK: - Recording

    var isRecording: Bool { phase == .recording }

    func recordButtonTapped() {
        switch phase {
        case .idle: startTake()
        case .countdown: cancelCountdown()
        case .recording: stopTake(good: false)
        }
    }

    /// `minimumCountIn` makes sure there's time to put a hand down after a gesture.
    func startTake(useCountdown: Bool = true, minimumCountIn: Int = 0) {
        guard phase == .idle, cameraReady else { return }
        let seconds = useCountdown ? max(settings.countdown, minimumCountIn) : 0
        if seconds > 0 {
            phase = .countdown(seconds)
            beep()
            countdownTimer?.invalidate()
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.tick()
            }
        } else {
            beginRecording()
        }
    }

    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        if case .countdown = phase { phase = .idle }
    }

    func retake() {
        guard phase == .recording else { return }
        stopTake(good: false, quiet: true)
        showToast("✋ Retake — Seg \(String(format: "%02d", segment)), take \(segmentTake)", color: .orange)
        startTake(minimumCountIn: 2)
    }

    /// ✊ Keep this take, move on to the next segment and count it in.
    func cut(gestureAt: Date? = nil) {
        switch phase {
        case .recording:
            stopTake(good: true, gestureAt: gestureAt, quiet: true)
            setSegment(segment + 1)
            showToast("✊ Cut — Segment \(segment) next", color: .green)
            startTake(minimumCountIn: 2)
        case .idle:
            // Nothing recorded yet for this segment: just start it.
            if hasTakes(inSegment: segment) { setSegment(segment + 1) }
            showToast("✊ Segment \(segment)", color: .green)
            startTake(minimumCountIn: 2)
        case .countdown:
            break
        }
    }

    /// Step the segment back or forward by hand (when not recording).
    func changeSegment(by delta: Int) {
        guard phase == .idle else { return }
        setSegment(max(1, segment + delta))
    }

    private func setSegment(_ value: Int) {
        segment = value
        let tried = store.takes
            .filter { $0.info.session == sessionName && $0.info.segment == value }
            .compactMap { $0.info.segmentTake }
            .max() ?? 0
        segmentTake = tried + 1
        saveSegment()
    }

    private func hasTakes(inSegment value: Int) -> Bool {
        store.takes.contains { $0.info.session == sessionName && $0.info.segment == value }
    }

    private func saveSegment() {
        UserDefaults.standard.set(segment, forKey: "segment")
        UserDefaults.standard.set(segmentTake, forKey: "segmentTake")
    }

    // MARK: - Focus

    /// Tap on the preview: focus and expose there (in preview coordinates).
    func focusTap(at point: CGPoint) {
        guard let layer = previewLayer else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
        manualFocusPoint = devicePoint
        objectFocusPoint = nil
        camera.focus(at: devicePoint)
        focus.set(CGRect(x: point.x - 45, y: point.y - 45, width: 90, height: 90), mode: .manual)
    }

    /// Long-press: back to automatic focus (follows her face).
    func resetFocus() {
        manualFocusPoint = nil
        objectFocusPoint = nil
        camera.focus(at: nil)
        lastFaceAt = .distantPast
        refreshAutoFocusTarget()
        showToast("Autofocus", color: .white)
    }

    /// She's holding something up (point in frame coordinates), or has put it away (nil).
    private func showingChanged(_ framePoint: CGPoint?) {
        guard manualFocusPoint == nil else { return } // a tapped focus point wins
        if let framePoint {
            let wasShowing = objectFocusPoint != nil
            let devicePoint = camera.devicePoint(forFramePoint: framePoint)
            objectFocusPoint = devicePoint
            camera.focus(at: devicePoint)
            refreshAutoFocusTarget()
            if !wasShowing { gestureProgress = nil }
        } else if objectFocusPoint != nil {
            objectFocusPoint = nil
            camera.focus(at: nil) // back to following her face
            lastFaceAt = .distantPast
            refreshAutoFocusTarget()
        }
    }

    private func updateFaces(_ objects: [AVMetadataObject]) {
        guard manualFocusPoint == nil, objectFocusPoint == nil, let layer = previewLayer else { return }
        let faces = objects.compactMap { $0 as? AVMetadataFaceObject }
        guard let face = faces.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
              let converted = layer.transformedMetadataObject(for: face) else { return }
        lastFaceAt = Date()
        focus.set(converted.bounds.insetBy(dx: -converted.bounds.width * 0.1, dy: -converted.bounds.height * 0.1), mode: .face)
    }

    /// Without a face, autofocus works on the middle of the frame (or the tapped point).
    private func refreshAutoFocusTarget() {
        guard let layer = previewLayer else { return }
        if let manual = manualFocusPoint {
            let p = layer.layerPointConverted(fromCaptureDevicePoint: manual)
            focus.set(CGRect(x: p.x - 45, y: p.y - 45, width: 90, height: 90), mode: .manual)
        } else if let object = objectFocusPoint {
            let p = layer.layerPointConverted(fromCaptureDevicePoint: object)
            focus.set(CGRect(x: p.x - 55, y: p.y - 55, width: 110, height: 110), mode: .object)
        } else if Date().timeIntervalSince(lastFaceAt) > 0.6 {
            let p = layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: 0.5, y: 0.5))
            focus.set(CGRect(x: p.x - 60, y: p.y - 60, width: 120, height: 120), mode: .auto)
        }
    }

    // MARK: - Sound

    private func routeChanged() {
        let wasExternal = meter.isExternal
        meter.updateRoute()
        if meter.isExternal && !wasExternal {
            showToast("🎙 \(meter.micName) connected", color: .green)
        } else if !meter.isExternal && wasExternal {
            showToast("🎙 External mic disconnected", color: .orange)
        }
    }

    private func checkWarnings() {
        meter.updateRoute()
        var warning: String?
        if settings.warnNoExternalMic && !meter.isExternal {
            warning = "No external mic — using the \(meter.micName)"
        }
        if phase == .recording, let start = recordingStart,
           Date().timeIntervalSince(max(start, meter.lastSoundAt)) > 4 {
            warning = "No sound detected — check the mic"
        }
        if let snoozed = snoozedWarning, snoozed.text == warning, Date() < snoozed.until {
            warning = nil
        }
        if warning != audioWarning { audioWarning = warning }
    }

    /// Tapping a warning hides it for two minutes.
    func dismissWarning() {
        if let audioWarning { snoozedWarning = (audioWarning, Date().addingTimeInterval(120)) }
        audioWarning = nil
    }

    func stopTake(good: Bool, gestureAt: Date? = nil, quiet: Bool = false) {
        guard phase == .recording, let take = currentTake else { return }
        let started = recordingStart
        phase = .idle
        currentTake = nil
        recordingStart = nil
        lastTakeID = take.id
        currentNumber = nextNumber
        if let tried = take.segmentTake, take.segment == segment {
            segmentTake = tried + 1
            saveSegment()
        }
        updateCaptureAngle(rawCaptureAngle)
        if good {
            flash(.green)
            showToast("👍 \(take.displayName) kept", color: .green)
        } else if !quiet {
            showToast("\(take.displayName) saved", color: .white)
        }
        let trim = settings.trimGesture
        camera.stopTake { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                var info = self.store.take(take.id)?.info ?? take
                info.finished = true
                info.totalBytes = result.bytes
                info.duration = result.duration
                info.good = info.good || good
                if good, trim, let gestureAt, let started {
                    let end = gestureAt.timeIntervalSince(started) - 0.4
                    if end > 0.5 && end < result.duration { info.trimEnd = end }
                }
                self.store.update(info)
                // Send the finished file to the Mac straight away.
                self.link.send(.takeInfo(info))
                if result.bytes > 0 && self.link.isConnected { self.upload(info.id, from: 0) }
                if !result.ok {
                    self.showToast("\(take.displayName) didn't record properly", color: .red)
                } else if result.audioBuffers == 0 {
                    self.showToast("⚠️ \(take.displayName) has no sound — check the mic", color: .yellow)
                }
            }
        }
    }

    func markLastGood() {
        guard let id = lastTakeID ?? store.lastTake?.id, let take = store.take(id) else { return }
        setGood(id, true)
        flash(.green)
        showToast("👍 \(take.info.displayName) kept", color: .green)
    }

    func setGood(_ id: UUID, _ good: Bool) {
        guard var info = store.take(id)?.info else { return }
        info.good = good
        if !good { info.trimEnd = nil }
        store.update(info)
        if info.finished { link.send(.takeInfo(info)) }
    }

    func flipCamera() {
        guard phase == .idle else { return }
        settings.frontCamera.toggle()
    }

    func resumeCamera() {
        camera.resume()
    }

    func retryTransfers() {
        didConnect()
    }

    func deleteTake(_ id: UUID) {
        store.remove(id)
    }

    // MARK: - Private

    private func wire() {
        gestures.tuning = settings.gestureSpeed.tuning
        gestures.disabled = Set(settings.disabledGestures.compactMap(HandGesture.init(rawValue:)))
        gestures.detectShowing = settings.focusOnShownObjects
        gestures.debug = settings.gestureDebug
        gestures.onDebug = { [weak self] text in
            guard let self, self.settings.gestureDebug, self.gestureDebugText != text else { return }
            self.gestureDebugText = text
        }
        gestures.onShowing = { [weak self] point in self?.showingChanged(point) }
        camera.onFaces = { [weak self] objects in self?.updateFaces(objects) }
        camera.onFocusAdjusting = { [weak self] adjusting in
            if self?.focus.adjusting != adjusting { self?.focus.adjusting = adjusting }
        }
        gestures.enabled = settings.gesturesEnabled
        gestures.onProgress = { [weak self] progress in
            guard let self, self.gestureProgress != progress else { return }
            self.gestureProgress = progress
        }
        gestures.onGesture = { [weak self] gesture, seenAt in
            self?.handleGesture(gesture, seenAt: seenAt)
        }
        camera.onNotice = { [weak self] notice in
            self?.cameraNotice = notice
        }
        camera.frameHandler = { [weak self] sampleBuffer, orientation in
            self?.processFrame(sampleBuffer, orientation: orientation)
        }
        link.onMessage = { [weak self] message, payload in
            self?.handle(message, payload)
        }
        link.onConnected = { [weak self] in
            self?.didConnect()
        }
    }

    private func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { video in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { done(video) }
            }
        }
    }

    private func configureCamera() {
        camera.configure(front: settings.frontCamera, uhd: settings.uhd, fps: settings.fps) { [weak self] device, mode in
            guard let self else { return }
            self.cameraReady = true
            self.activeMode = mode
            if let mode, mode.fps < self.settings.fps || (self.settings.uhd && mode.width < 3840) {
                self.showToast("This camera can do \(mode.label) at most", color: .yellow)
            }
            self.setUpRotation(device)
        }
    }

    private func setUpRotation(_ device: AVCaptureDevice?) {
        rotationObservers.removeAll()
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewAngle(coordinator.videoRotationAngleForHorizonLevelPreview)
        updateCaptureAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservers = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.applyPreviewAngle(angle) }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                DispatchQueue.main.async { self?.updateCaptureAngle(angle) }
            },
        ]
    }

    private func applyPreviewAngle(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    func cycleOrientation() {
        guard phase == .idle else { return }
        let all = OrientationMode.allCases
        let next = all[(all.firstIndex(of: orientationMode)! + 1) % all.count]
        orientationMode = next
        showToast(next.label, color: .white)
    }

    private func updateCaptureAngle(_ raw: CGFloat) {
        rawCaptureAngle = raw
        // The orientation is fixed for the length of a take.
        guard phase != .recording else { return }
        let angle: CGFloat
        switch orientationMode {
        case .auto:
            angle = raw
        case .portrait:
            angle = (raw == 90 || raw == 270) ? raw : 90
        case .landscape:
            angle = (raw == 0 || raw == 180) ? raw : 0
        }
        captureAngle = angle
        recordsLandscape = angle == 0 || angle == 180
        camera.setRotation(angle)
    }

    private func settingsChanged(from old: CaptureSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
        gestures.tuning = settings.gestureSpeed.tuning
        gestures.disabled = Set(settings.disabledGestures.compactMap(HandGesture.init(rawValue:)))
        gestures.detectShowing = settings.focusOnShownObjects
        gestures.debug = settings.gestureDebug
        if !settings.gestureDebug { gestureDebugText = nil }
        gestures.enabled = settings.gesturesEnabled
        if !settings.gesturesEnabled { gestureProgress = nil }
        previewEnabled = settings.sendPreview
        previewMirrored = settings.frontCamera
        if cameraReady && (old.frontCamera != settings.frontCamera || old.uhd != settings.uhd || old.fps != settings.fps) {
            configureCamera()
        }
    }

    private func tick() {
        guard case let .countdown(n) = phase else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        if n <= 1 {
            countdownTimer?.invalidate()
            countdownTimer = nil
            beginRecording()
        } else {
            phase = .countdown(n - 1)
            beep()
        }
    }

    private func beginRecording() {
        let info = TakeInfo(id: UUID(), number: nextNumber, session: sessionName, createdAt: Date(),
                            finished: false, totalBytes: 0, duration: 0, good: false, trimEnd: nil,
                            segment: segment, segmentTake: segmentTake)
        currentTake = info
        currentNumber = info.number
        nextNumber += 1
        store.add(info)
        link.send(.takeInfo(info))

        let angle = captureAngle
        camera.setRotation(angle)
        let fps = activeMode?.fps ?? settings.fps
        let width = activeMode?.width ?? (settings.uhd ? 3840 : 1920)
        let config = TakeWriter.Config(hevc: settings.hevc, rotation: angle, fps: fps,
                                       bitrate: settings.quality.bitrate(width: width, fps: fps, hevc: settings.hevc))
        camera.startTake(fileURL: store.fileURL(for: info.id), config: config)
        recordingStart = Date()
        meter.resetSilenceTimer()
        phase = .recording
        flash(.red)
    }

    private func processFrame(_ sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        gestures.process(pixelBuffer, orientation: orientation)
        if previewEnabled && link.hasReadyPeer {
            let link = self.link
            previewEncoder.encode(pixelBuffer, orientation: orientation, mirrored: previewMirrored) { jpeg in
                link.sendPreview(jpeg)
            }
        }
    }

    private func handleGesture(_ gesture: HandGesture, seenAt: Date) {
        // Right after a take starts her hand may still be coming down from the last gesture;
        // don't let that end the new take.
        if phase == .recording, let start = recordingStart, Date().timeIntervalSince(start) < 0.8 { return }
        let action: String
        switch gesture {
        case .openPalm:
            switch phase {
            case .idle: action = "Start"; startTake()
            case .recording: action = "Retake"; retake()
            case .countdown: action = "Already counting in"
            }
        case .fist:
            switch phase {
            case .countdown: action = "Already counting in"
            case .recording:
                cut(gestureAt: seenAt)
                action = "Cut → Segment \(segment)"
            case .idle:
                cut()
                action = "Segment \(segment)"
            }
        case .thumbsUp:
            switch phase {
            case .recording: action = "Kept"; stopTake(good: true, gestureAt: seenAt)
            case .idle: action = "Kept last take"; markLastGood()
            case .countdown: action = "Cancelled"; cancelCountdown()
            }
        case .peace:
            switch phase {
            case .recording: action = "Stopped"; stopTake(good: false)
            case .countdown: action = "Cancelled"; cancelCountdown()
            case .idle: action = "Nothing to stop"
            }
        }
        showRecognized(gesture, action: action)
    }

    private func showRecognized(_ gesture: HandGesture, action: String) {
        // Heard and seen the instant it registers, so she can drop her hand.
        if settings.countInBeeps { AudioServicesPlaySystemSound(1016) }
        flash(.green)
        recognizedWork?.cancel()
        recognized = RecognizedGesture(gesture: gesture, action: action)
        lastGestureForMac = (gesture, Date())
        let work = DispatchWorkItem { [weak self] in self?.recognized = nil }
        recognizedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func beep() {
        guard settings.countInBeeps else { return }
        AudioServicesPlaySystemSound(1057)
    }

    private func handle(_ message: Message, _ payload: Data) {
        switch message {
        case let .session(name, nextTake):
            if name != sessionName {
                sessionName = name
                UserDefaults.standard.set(name, forKey: "sessionName")
                if phase != .recording {
                    nextNumber = max(1, nextTake)
                    setSegment(1)
                }
            } else if nextTake > nextNumber && phase != .recording {
                nextNumber = nextTake
            }
        case let .takeStatus(id, have, saved):
            if saved {
                uploading.remove(id)
                store.markSynced(id, deleteFile: settings.deleteAfterTransfer)
            } else if let take = store.take(id), take.info.finished, !take.fileDeleted,
                      have < take.info.totalBytes, !uploading.contains(id) {
                upload(id, from: have)
            }
        case let .command(command):
            switch command {
            case .record:
                if phase == .idle { startTake() }
            case .stop:
                if phase == .recording { stopTake(good: false) } else { cancelCountdown() }
            case .retake:
                if phase == .recording { retake() } else if phase == .idle { startTake() }
            case .keep:
                if phase == .recording { stopTake(good: true) } else if phase == .idle { markLastGood() }
            case .markLastGood:
                markLastGood()
            case .cut:
                cut()
            }
        default:
            break
        }
    }

    private func didConnect() {
        guard link.isConnected else { return }
        for take in store.takes where !take.synced && take.info.finished && !take.fileDeleted {
            link.send(.takeInfo(take.info))
        }
        if let currentTake { link.send(.takeInfo(currentTake)) }
        sendStatus()
    }

    /// Sends the rest of a finished take from its local file, 1 MB at a time.
    private let uploadQueue = DispatchQueue(label: "autokam.upload", qos: .userInitiated)

    /// Sends the rest of a finished take from its local file: 4 MB pieces read off the main
    /// thread, with up to four in flight so the network never sits idle.
    private func upload(_ id: UUID, from offset: Int64) {
        guard !uploading.contains(id) else { return }
        let url = store.fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        uploading.insert(id)
        let link = self.link
        uploadQueue.async { [weak self] in
            defer { DispatchQueue.main.async { self?.uploading.remove(id) } }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            // Start at 0 and add the four slots: libdispatch traps if a semaphore is freed while
            // its count is below the value it was created with, which happens with value: 4
            // once the last piece's completion releases it.
            let inFlight = DispatchSemaphore(value: 0)
            for _ in 0 ..< 4 { inFlight.signal() }
            let failedLock = NSLock()
            var failed = false
            var position = offset
            do { try handle.seek(toOffset: UInt64(offset)) } catch { return }
            while true {
                failedLock.lock(); let stop = failed; failedLock.unlock()
                if stop || !link.hasReadyPeer { break }
                guard let data = try? handle.read(upToCount: 4 << 20), !data.isEmpty else { break }
                if inFlight.wait(timeout: .now() + 30) == .timedOut { break }
                link.sendFileChunk(id: id, offset: position, data: data) { ok in
                    if !ok { failedLock.lock(); failed = true; failedLock.unlock() }
                    inFlight.signal()
                }
                position += Int64(data.count)
            }
            // Let the last pieces go out before this take can be picked up again.
            for _ in 0 ..< 4 { _ = inFlight.wait(timeout: .now() + 30) }
        }
    }

    private func sendStatus() {
        guard link.isConnected else { return }
        var countdown: Int?
        if case let .countdown(n) = phase { countdown = n }
        let elapsed = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        let level = UIDevice.current.batteryLevel
        let status = PhoneStatus(
            recording: phase == .recording,
            takeNumber: currentNumber,
            elapsed: elapsed,
            camera: settings.frontCamera ? "Front" : "Back",
            resolution: activeMode?.label ?? (settings.uhd ? "4K" : "1080p"),
            gesture: gestureProgress?.gesture.rawValue,
            gestureProgress: gestureProgress?.progress ?? 0,
            pendingUploads: store.pendingCount,
            countdown: countdown,
            battery: level >= 0 ? Double(level) : nil,
            micName: meter.micName,
            micExternal: meter.isExternal,
            warning: audioWarning ?? cameraNotice,
            segment: segment,
            segmentTake: currentTake?.segmentTake ?? segmentTake,
            lastGesture: lastGestureForMac?.0.rawValue,
            lastGestureAt: lastGestureForMac?.1.timeIntervalSince1970
        )
        link.send(.status(status))
    }

    private func flash(_ color: Color) {
        flashColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.flashColor = nil
        }
    }

    private func showToast(_ text: String, color: Color) {
        toastWork?.cancel()
        toast = Toast(text: text, color: color)
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}
#endif
