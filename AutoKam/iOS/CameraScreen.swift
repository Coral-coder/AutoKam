#if os(iOS)
import SwiftUI
import AVFoundation

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onLayer: (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect // show exactly what's recorded
        let layer = view.previewLayer
        DispatchQueue.main.async { onLayer(layer) }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

struct CameraScreen: View {
    @ObservedObject var model: CameraAppModel
    @ObservedObject var link: PhoneLink
    @ObservedObject var store: TakeStore
    @State private var showSettings = false
    @State private var showTakes = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: model.camera.session) { layer in
                model.attachPreview(layer)
            }
            .ignoresSafeArea()

            if model.isRecording {
                Rectangle()
                    .strokeBorder(Color.red, lineWidth: 6)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if let flash = model.flashColor {
                flash.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
            }

            GeometryReader { geo in
                if geo.size.width > geo.size.height {
                    // Landscape: controls run down the right-hand side.
                    HStack(spacing: 12) {
                        VStack(spacing: 10) {
                            topBar
                            gestureStrip
                            noticeView
                            Spacer()
                            countdownView
                            Spacer()
                            toastView
                        }
                        controls(vertical: true)
                            .frame(width: 84)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                } else {
                    VStack(spacing: 12) {
                        topBar
                        gestureStrip
                        noticeView
                        Spacer()
                        countdownView
                        Spacer()
                        toastView
                        controls(vertical: false)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }

            if model.accessDenied {
                permissionMessage
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .statusBarHidden()
        .onAppear { model.start() }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model, link: link, store: store)
        }
        .sheet(isPresented: $showTakes) {
            TakesView(model: model, store: store)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var noticeView: some View {
        if let notice = model.cameraNotice {
            Button { model.resumeCamera() } label: {
                Label(notice, systemImage: notice.hasPrefix("On a call") ? "phone.fill" : "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.orange.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private var countdownView: some View {
        if case let .countdown(n) = model.phase {
            Text("\(n)")
                .font(.system(size: 160, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 12)
                .transition(.scale)
                .id(n)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast.text)
                .font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(toast.color)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var orientationButton: some View {
        Button { model.cycleOrientation() } label: {
            HStack(spacing: 5) {
                Image(systemName: model.orientationMode == .auto
                      ? (model.recordsLandscape ? "rectangle" : "rectangle.portrait")
                      : model.orientationMode.symbol)
                Text(model.orientationMode == .auto
                     ? "Auto · \(model.recordsLandscape ? "16:9" : "9:16")"
                     : model.orientationMode.shortLabel)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
        .disabled(model.phase != .idle)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button { showSettings = true } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(link.isConnected ? Color.green : (link.connectingName != nil ? Color.yellow : Color.gray))
                        .frame(width: 9, height: 9)
                    Text(link.connectedName ?? (link.connectingName.map { "Connecting to \($0)…" } ?? "Looking for your Mac…"))
                        .lineLimit(1)
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .foregroundStyle(.white)

            orientationButton

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "Take %03d", model.currentNumber))
                    .font(.headline.monospacedDigit())
                if model.isRecording, let start = model.recordingStart {
                    TimelineView(.periodic(from: start, by: 0.5)) { context in
                        Text(Self.format(context.date.timeIntervalSince(start)))
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.red)
                    }
                } else if !model.sessionName.isEmpty {
                    Text(model.sessionName)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var gestureStrip: some View {
        if model.settings.gesturesEnabled {
            HStack(spacing: 14) {
                ForEach(HandGesture.allCases, id: \.self) { gesture in
                    let active = model.gestureProgress?.gesture == gesture
                    HStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .trim(from: 0, to: CGFloat(active ? (model.gestureProgress?.progress ?? 0) : 0))
                                .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 30, height: 30)
                            Text(gesture.emoji).font(.system(size: active ? 20 : 16))
                        }
                        Text(label(for: gesture))
                            .font(.caption2.weight(.semibold))
                    }
                    .opacity(active ? 1 : 0.75)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func label(for gesture: HandGesture) -> String {
        switch gesture {
        case .openPalm: return model.isRecording ? "Retake" : "Start"
        case .thumbsUp: return "Keep"
        case .peace: return "Stop"
        }
    }

    private func controls(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            Button { showTakes = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "film.stack")
                        .font(.title2)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                    if store.pendingCount > 0 {
                        Text("\(store.pendingCount)")
                            .font(.caption2.bold())
                            .padding(5)
                            .background(Color.orange, in: Circle())
                    }
                }
            }

            Spacer()

            if model.isRecording {
                Button { model.retake() } label: {
                    Label("Retake", systemImage: "arrow.counterclockwise")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
            }

            Button { model.recordButtonTapped() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 5).frame(width: 82, height: 82)
                    if model.isRecording {
                        RoundedRectangle(cornerRadius: 8).fill(Color.red).frame(width: 34, height: 34)
                    } else {
                        Circle().fill(Color.red).frame(width: 66, height: 66)
                    }
                }
            }
            .disabled(!model.cameraReady)

            Spacer()

            Button {
                if model.isRecording { model.stopTake(good: true) } else { model.markLastGood() }
            } label: {
                Image(systemName: "hand.thumbsup.fill")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
            }

            if !model.isRecording {
                Spacer()
                Button { model.flipCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title2)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(model.phase != .idle)
            }
        }
        .foregroundStyle(.white)
    }

    private var permissionMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash").font(.largeTitle)
            Text("AutoKam needs the camera and microphone.")
                .font(.headline)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct SettingsView: View {
    @ObservedObject var model: CameraAppModel
    @ObservedObject var link: PhoneLink
    @ObservedObject var store: TakeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if link.macs.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Looking for AutoKam on your Mac…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(link.macs) { mac in
                        Button { link.choose(mac) } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(mac.name)
                                Spacer()
                                if link.connectedName == mac.name {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else if link.connectingName == mac.name {
                                    ProgressView()
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Computer")
                } footer: {
                    Text("Open AutoKam on your Mac. Both devices need Wi-Fi turned on; they don't have to be on the same network.")
                }

                Section("Session") {
                    LabeledContent("Folder on Mac", value: model.sessionName.isEmpty ? "—" : model.sessionName)
                    LabeledContent("Next take", value: String(format: "%03d", model.currentNumber))
                }

                Section {
                    Toggle("Hand gestures", isOn: $model.settings.gesturesEnabled)
                    Picker("Countdown", selection: $model.settings.countdown) {
                        Text("Off").tag(0)
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                    }
                    Toggle("Cut the 👍 off kept takes", isOn: $model.settings.trimGesture)
                } header: {
                    Text("Gestures")
                } footer: {
                    Text("Hold a gesture still for about a second.\n✋ Open hand: start recording — or, while recording, toss this take and start another.\n👍 Thumbs up: stop and keep this take (it goes in the Good Takes folder). When stopped, keeps the last take.\n✌️ Peace sign: stop without keeping.")
                }

                Section("Video") {
                    Picker("Camera", selection: $model.settings.frontCamera) {
                        Text("Front (selfie)").tag(true)
                        Text("Back").tag(false)
                    }
                    .disabled(model.phase != .idle)
                    Picker("Resolution", selection: $model.settings.uhd) {
                        Text("1080p HD").tag(false)
                        Text("4K").tag(true)
                    }
                    .disabled(model.phase != .idle)
                    Toggle("Smaller files (HEVC)", isOn: $model.settings.hevc)
                    Toggle("Live view on Mac", isOn: $model.settings.sendPreview)
                }

                Section {
                    Toggle("Delete from iPhone once on Mac", isOn: $model.settings.deleteAfterTransfer)
                    LabeledContent("Waiting to send", value: "\(store.pendingCount)")
                    Button("Send waiting takes now") { model.retryTransfers() }
                        .disabled(!link.isConnected || store.pendingCount == 0)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Takes are streamed to the Mac while you record. Anything that couldn't be sent is kept here and sent as soon as the Mac is back.")
                }
            }
            .navigationTitle("AutoKam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct TakesView: View {
    @ObservedObject var model: CameraAppModel
    @ObservedObject var store: TakeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.takes.isEmpty {
                    Text("No takes yet.").foregroundStyle(.secondary)
                }
                ForEach(store.takes.reversed()) { take in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(take.info.displayName).font(.headline)
                            Text("\(take.info.session.isEmpty ? "No session" : take.info.session) · \(CameraScreen.format(take.info.duration))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        status(for: take)
                        Button {
                            model.setGood(take.id, !take.info.good)
                        } label: {
                            Image(systemName: take.info.good ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .foregroundStyle(take.info.good ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button(role: .destructive) { model.deleteTake(take.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Takes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func status(for take: LocalTake) -> some View {
        if take.synced {
            Label("On Mac", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly).foregroundStyle(.green)
        } else if !take.info.finished {
            Label("Recording", systemImage: "record.circle")
                .labelStyle(.iconOnly).foregroundStyle(.red)
        } else {
            Label("Waiting", systemImage: "arrow.up.circle")
                .labelStyle(.iconOnly).foregroundStyle(.orange)
        }
    }
}
#endif
