#if os(macOS)
import SwiftUI
import AppKit

struct ReceiverScreen: View {
    @ObservedObject var model: ReceiverModel
    @AppStorage("walkthroughSeen") private var walkthroughSeen = false
    @State private var showWalkthrough = false

    var body: some View {
        HSplitView {
            PhonePane(model: model)
                .frame(minWidth: 380, idealWidth: 460, maxWidth: 640)
            TakesPane(model: model)
                .frame(minWidth: 460)
        }
        .toolbar {
            ToolbarItem {
                Button { showWalkthrough = true } label: {
                    Label("How it works", systemImage: "questionmark.circle")
                }
            }
        }
        .sheet(isPresented: $showWalkthrough) {
            WalkthroughView {
                walkthroughSeen = true
                showWalkthrough = false
            }
        }
        .onAppear {
            if !walkthroughSeen { showWalkthrough = true }
        }
    }
}

private struct PhonePane: View {
    @ObservedObject var model: ReceiverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.phoneName ?? "Waiting for your iPhone…")
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(model.hasPhone ? Color.green : (model.listening ? Color.orange : Color.red))
                    .frame(width: 10, height: 10)
            }

            if let warning = model.phoneStatus?.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.yellow.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black)
                if let image = model.preview {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "video.badge.waveform")
                            .font(.system(size: 42))
                        Text(model.hasPhone ? "Live view is off on the iPhone" : "Open AutoKam on your iPhone.\nIt finds this Mac on its own.")
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                }
                overlay
            }
            .frame(maxHeight: .infinity)

            controls

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(HandGesture.allCases, id: \.self) { gesture in
                        HStack {
                            Text(gesture.emoji + gesture.emoji).frame(width: 44)
                            Text(gesture.meaning)
                        }
                    }
                    Text("Both hands, same shape, held for a moment. Every take lands in All Takes; kept takes (✊ and 👍) are also copied to Good Takes with the gesture trimmed off — import that folder into your editor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Gestures")
            }
        }
        .padding()
    }

    private var subtitle: String {
        if let error = model.listenerError { return "Network problem: \(error)" }
        guard let status = model.phoneStatus else {
            return model.listening ? "AutoKam is ready on this Mac" : "Starting…"
        }
        var parts = ["\(status.camera) camera", status.resolution]
        if let mic = status.micName { parts.append("🎙 \(mic)") }
        if let battery = status.battery { parts.append("Battery \(Int(battery * 100))%") }
        if status.pendingUploads > 0 { parts.append("\(status.pendingUploads) waiting to send") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var overlay: some View {
        if let status = model.phoneStatus {
            VStack {
                HStack {
                    if status.recording {
                        Label(String(format: "REC  %@  %d:%02d", Self.takeLabel(status), Int(status.elapsed) / 60, Int(status.elapsed) % 60),
                              systemImage: "record.circle.fill")
                            .font(.headline.monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.red, in: Capsule())
                            .foregroundStyle(.white)
                    } else {
                        Text("Next: \(Self.takeLabel(status))")
                            .font(.headline.monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    if let raw = status.gesture, let gesture = HandGesture(rawValue: raw) {
                        HStack(spacing: 6) {
                            Text(gesture.emoji).font(.title2)
                            ProgressView(value: status.gestureProgress)
                                .frame(width: 60)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                Spacer()
                if let raw = status.lastGesture, let gesture = HandGesture(rawValue: raw),
                   let at = status.lastGestureAt, Date().timeIntervalSince1970 - at < 1.6 {
                    VStack(spacing: 2) {
                        Text(gesture.emoji).font(.system(size: 64))
                        Text(gesture.meaning).font(.headline).multilineTextAlignment(.center)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    Spacer()
                }
                if let countdown = status.countdown {
                    Text("\(countdown)")
                        .font(.system(size: 120, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 10)
                    Spacer()
                }
            }
            .padding(10)
        }
    }

    static func takeLabel(_ status: PhoneStatus) -> String {
        if let segment = status.segment, let take = status.segmentTake {
            return String(format: "Seg %02d · Take %02d", segment, take)
        }
        return String(format: "Take %03d", status.takeNumber)
    }

    private var controls: some View {
        let recording = model.phoneStatus?.recording ?? false
        return HStack(spacing: 10) {
            Button {
                model.send(recording ? .stop : .record)
            } label: {
                Label(recording ? "Stop" : "Record", systemImage: recording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("r", modifiers: .command)
            .tint(.red)

            Button {
                model.send(.retake)
            } label: {
                Label("Retake", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button {
                model.send(.cut)
            } label: {
                Label("Cut", systemImage: "scissors")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("g", modifiers: .command)
            .help("Keep this take and count in the next segment (⌘G)")

            Button {
                model.send(.keep)
            } label: {
                Label("Keep", systemImage: "hand.thumbsup.fill")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("k", modifiers: .command)
            .tint(.green)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.hasPhone)
    }
}

private struct TakesPane: View {
    @ObservedObject var model: ReceiverModel
    @State private var draftSession = ""
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Session name", text: $draftSession)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .onSubmit { model.setSession(draftSession) }
                Button("Rename") { model.setSession(draftSession) }
                    .disabled(draftSession == model.sessionName)
                Button("New Session") { model.newSession() }
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(model.rootURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Change…") { model.chooseFolder() }
                Button("All Takes") { model.openSessionFolder() }
                Button("Good Takes") { model.openGoodFolder() }
            }
            .font(.callout)

            Picker("", selection: $showAll) {
                Text("This session").tag(false)
                Text("Everything").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)

            let list = showAll ? model.takes : model.sessionTakes
            if list.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "film.stack").font(.system(size: 40))
                    Text("No takes yet").font(.headline)
                    Text("Takes show up here while they're being recorded.")
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            } else {
                List(list) { take in
                    TakeRow(model: model, take: take, showSession: showAll)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            let good = model.sessionTakes.filter { $0.info.good }.count
            Text("\(model.sessionTakes.count) takes in this session · \(good) kept")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { draftSession = model.sessionName }
        .onChange(of: model.sessionName) { _, name in draftSession = name }
    }
}

private struct TakeRow: View {
    @ObservedObject var model: ReceiverModel
    let take: ReceivedTake
    let showSession: Bool

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(take.info.displayName).font(.headline)
                    if take.info.good {
                        Text("GOOD")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.25), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(take.problem == nil ? Color.secondary : Color.red)
                if !take.saved && take.info.finished {
                    ProgressView(value: take.progress)
                        .frame(maxWidth: 220)
                }
            }
            Spacer()
            Button {
                model.toggleGood(take)
            } label: {
                Image(systemName: take.info.good ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(take.info.good ? Color.green : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help(take.info.good ? "Remove from Good Takes" : "Add to Good Takes")
            .disabled(!take.saved)

            Button {
                model.reveal(take)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(take) }
        .contextMenu {
            Button("Open") { model.open(take) }.disabled(take.finalPath == nil)
            Button("Show in Finder") { model.reveal(take) }
            Button(take.info.good ? "Remove from Good Takes" : "Add to Good Takes") { model.toggleGood(take) }
                .disabled(!take.saved)
            Divider()
            Button("Remove from List") { model.forget(take) }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if take.problem != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if take.saved {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if !take.info.finished {
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
        }
    }

    private var detail: String {
        if let problem = take.problem { return problem }
        var parts: [String] = []
        if showSession { parts.append(take.info.session) }
        if !take.info.finished {
            parts.append("Recording on the iPhone…")
        } else {
            let seconds = Int(take.info.duration.rounded())
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
            parts.append(ByteCountFormatter.string(fromByteCount: take.info.totalBytes, countStyle: .file))
            if !take.saved { parts.append("arriving \(Int(take.progress * 100))%") }
        }
        parts.append(take.info.createdAt.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }
}
#endif
