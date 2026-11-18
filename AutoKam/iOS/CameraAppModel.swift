#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit

struct CaptureSettings: Codable, Equatable {
    var gesturesEnabled = true
    var countdown = 3
    var uhd = false
    var hevc = true
    var trimGesture = true
    var deleteAfterTransfer = true
    var frontCamera = true
    var sendPreview = true
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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recordingStart: Date?
    @Published private(set) var currentNumber = 1
    @Published private(set) var sessionName: String
    @Published var settings: CaptureSettings {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published private(set) var gestureProgress: GestureProgress?
    @Published private(set) var toast: Toast?
    @Published private(set) var flashColor: Color?
    @Published private(set) var cameraReady = false
    @Published private(set) var accessDenied = false
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
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.sendStatus()
        }
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

    func startTake(useCountdown: Bool = true) {
        guard phase == .idle, cameraReady else { return }
        let seconds = useCountdown ? settings.countdown : 0
        if seconds > 0 {
            phase = .countdown(seconds)
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
        showToast("✋ Retake — get ready", color: .orange)
        startTake()
    }

    func stopTake(good: Bool, gestureAt: Date? = nil, quiet: Bool = false) {
        guard phase == .recording, let take = currentTake else { return }
        let started = recordingStart
        phase = .idle
        currentTake = nil
        recordingStart = nil
        lastTakeID = take.id
        currentNumber = nextNumber
        updateCaptureAngle(rawCaptureAngle)
        if good {
            flash(.green)
            showToast("👍 \(take.displayName) kept", color: .green)
        } else if !quiet {
            showToast("\(take.displayName) saved", color: .white)
        }
        let trim = settings.trimGesture
        camera.stopTake { [weak self] bytes, duration, ok in
            DispatchQueue.main.async {
                guard let self else { return }
                var info = self.store.take(take.id)?.info ?? take
                info.finished = true
                info.totalBytes = bytes
                info.duration = duration
                info.good = info.good || good
                if good, trim, let gestureAt, let started {
                    let end = gestureAt.timeIntervalSince(started) - 0.4
                    if end > 0.5 && end < duration { info.trimEnd = end }
                }
                self.store.update(info)
                self.link.send(.takeInfo(info))
                if !ok { self.showToast("\(take.displayName) didn't record properly", color: .red) }
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

    func retryTransfers() {
        didConnect()
    }

    func deleteTake(_ id: UUID) {
        store.remove(id)
    }

    // MARK: - Private

    private func wire() {
        gestures.enabled = settings.gesturesEnabled
        gestures.onProgress = { [weak self] progress in
            guard let self, self.gestureProgress != progress else { return }
            self.gestureProgress = progress
        }
        gestures.onGesture = { [weak self] gesture, seenAt in
            self?.handleGesture(gesture, seenAt: seenAt)
        }
        camera.frameHandler = { [weak self] sampleBuffer in
            self?.processFrame(sampleBuffer)
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
        camera.configure(front: settings.frontCamera, uhd: settings.uhd) { [weak self] device in
            guard let self else { return }
            self.cameraReady = true
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
        gestures.enabled = settings.gesturesEnabled
        if !settings.gesturesEnabled { gestureProgress = nil }
        previewEnabled = settings.sendPreview
        previewMirrored = settings.frontCamera
        if cameraReady && (old.frontCamera != settings.frontCamera || old.uhd != settings.uhd) {
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
        }
    }

    private func beginRecording() {
        let info = TakeInfo(id: UUID(), number: nextNumber, session: sessionName, createdAt: Date(),
                            finished: false, totalBytes: 0, duration: 0, good: false, trimEnd: nil)
        currentTake = info
        currentNumber = info.number
        nextNumber += 1
        store.add(info)
        link.send(.takeInfo(info))

        let angle = captureAngle
        camera.setRotation(angle)
        let config = TakeWriter.Config(hevc: settings.hevc, expectPortrait: angle == 90 || angle == 270)
        let link = self.link
        let id = info.id
        camera.startTake(fileURL: store.fileURL(for: id), config: config) { data, offset in
            link.sendLiveChunk(id: id, offset: offset, data: data)
        }
        recordingStart = Date()
        phase = .recording
        flash(.red)
    }

    private func processFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        gestures.process(pixelBuffer)
        if previewEnabled && link.hasReadyPeer {
            let link = self.link
            previewEncoder.encode(pixelBuffer, mirrored: previewMirrored) { jpeg in
                link.sendPreview(jpeg)
            }
        }
    }

    private func handleGesture(_ gesture: HandGesture, seenAt: Date) {
        switch gesture {
        case .openPalm:
            switch phase {
            case .idle: startTake()
            case .recording: retake()
            case .countdown: break
            }
        case .thumbsUp:
            switch phase {
            case .recording: stopTake(good: true, gestureAt: seenAt)
            case .idle: markLastGood()
            case .countdown: cancelCountdown()
            }
        case .peace:
            switch phase {
            case .recording: stopTake(good: false)
            case .countdown: cancelCountdown()
            case .idle: break
            }
        }
    }

    private func handle(_ message: Message, _ payload: Data) {
        switch message {
        case let .session(name, nextTake):
            if name != sessionName {
                sessionName = name
                UserDefaults.standard.set(name, forKey: "sessionName")
                if phase != .recording { nextNumber = max(1, nextTake) }
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
    private func upload(_ id: UUID, from offset: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: store.fileURL(for: id)) else { return }
        uploading.insert(id)
        sendNextChunk(id, handle, offset)
    }

    private func sendNextChunk(_ id: UUID, _ handle: FileHandle, _ offset: Int64) {
        guard link.isConnected else {
            uploading.remove(id)
            try? handle.close()
            return
        }
        var data = Data()
        do {
            try handle.seek(toOffset: UInt64(offset))
            data = try handle.read(upToCount: 1 << 20) ?? Data()
        } catch {
            data = Data()
        }
        if data.isEmpty {
            try? handle.close()
            uploading.remove(id)
            return
        }
        link.send(.chunk(id: id, offset: offset), payload: data) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.sendNextChunk(id, handle, offset + Int64(data.count))
                } else {
                    self.uploading.remove(id)
                    try? handle.close()
                }
            }
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
            resolution: settings.uhd ? "4K" : "1080p",
            gesture: gestureProgress?.gesture.rawValue,
            gestureProgress: gestureProgress?.progress ?? 0,
            pendingUploads: store.pendingCount,
            countdown: countdown,
            battery: level >= 0 ? Double(level) : nil
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
