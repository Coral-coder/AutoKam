#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import Network

struct ReceivedTake: Identifiable, Codable, Hashable {
    var info: TakeInfo
    var have: Int64 = 0
    var saved = false
    var partialPath: String
    var finalPath: String?
    var goodPath: String?
    var problem: String?

    var id: UUID { info.id }
    var progress: Double {
        guard info.totalBytes > 0 else { return 0 }
        return min(1, Double(have) / Double(info.totalBytes))
    }
}

/// Listens for the iPhone, writes takes as they stream in, and files them:
///   <folder>/<session>/All Takes/Take 001.mov
///   <folder>/<session>/Good Takes/Take 001.mov   (👍 takes, with the gesture cut off)
final class ReceiverModel: ObservableObject {
    @Published private(set) var takes: [ReceivedTake] = []
    @Published private(set) var phoneName: String?
    @Published private(set) var phoneStatus: PhoneStatus?
    @Published private(set) var preview: NSImage?
    @Published private(set) var listening = false
    @Published private(set) var listenerError: String?
    @Published private(set) var sessionName: String
    @Published private(set) var rootURL: URL

    private var listener: NWListener?
    private var peers: [PeerConnection] = []
    private var handles: [UUID: FileHandle] = [:]
    private var finalizing = Set<UUID>()
    private var filingGood = Set<UUID>()
    private var activity: NSObjectProtocol?
    private var scopedURL: URL?

    private static let defaultRoot: URL = {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Movies/AutoKam", isDirectory: true)
    }()

    private var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("AutoKam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("takes.json")
    }

    init() {
        let defaults = UserDefaults.standard
        sessionName = defaults.string(forKey: "sessionName") ?? Self.newSessionName()
        rootURL = Self.defaultRoot
        if let bookmark = defaults.data(forKey: "rootBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() { scopedURL = url }
                rootURL = url
            }
        }
        loadTakes()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Receiving takes from iPhone")
        startListening()
    }

    // MARK: - User actions

    var sessionTakes: [ReceivedTake] {
        takes.filter { $0.info.session == sessionName }
    }

    func setSession(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != sessionName else { return }
        sessionName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "sessionName")
        broadcast(.session(name: trimmed, nextTake: nextTakeNumber(for: trimmed)))
    }

    func newSession() {
        setSession(Self.newSessionName())
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose where AutoKam saves your takes."
        panel.directoryURL = rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "rootBookmark")
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        rootURL = url
    }

    func openSessionFolder() {
        let dir = sessionDirectory(for: sessionName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func openGoodFolder() {
        let dir = sessionDirectory(for: sessionName).appendingPathComponent("Good Takes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func reveal(_ take: ReceivedTake) {
        let path = take.goodPath ?? take.finalPath ?? take.partialPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func open(_ take: ReceivedTake) {
        guard let path = take.finalPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func toggleGood(_ take: ReceivedTake) {
        guard let i = index(take.id) else { return }
        takes[i].info.good.toggle()
        if !takes[i].info.good { takes[i].info.trimEnd = nil }
        applyGood(take.id)
        persist()
    }

    func forget(_ take: ReceivedTake) {
        takes.removeAll { $0.id == take.id }
        persist()
    }

    func send(_ command: RemoteCommand) {
        broadcast(.command(command))
    }

    var hasPhone: Bool { !peers.isEmpty && phoneName != nil }

    // MARK: - Listening

    private func startListening() {
        do {
            let listener = try NWListener(using: AutoKamService.tcpParameters())
            listener.service = NWListener.Service(type: AutoKamService.type)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listening = true
                    self.listenerError = nil
                case let .failed(error):
                    self.listening = false
                    self.listenerError = error.localizedDescription
                    self.listener?.cancel()
                    self.listener = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startListening() }
                case .cancelled:
                    self.listening = false
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            listenerError = error.localizedDescription
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startListening() }
        }
    }

    private func accept(_ connection: NWConnection) {
        let peer = PeerConnection(connection)
        peers.append(peer)
        peer.onMessage = { [weak self, weak peer] message, payload in
            guard let self, let peer else { return }
            self.handle(message, payload, from: peer)
        }
        peer.onClose = { [weak self, weak peer] in
            guard let self else { return }
            self.peers.removeAll { $0 === peer || $0.isClosed }
            if self.peers.isEmpty {
                self.phoneName = nil
                self.phoneStatus = nil
                self.preview = nil
                self.closeAllHandles()
            }
        }
        peer.start()
    }

    private func broadcast(_ message: Message) {
        for peer in peers { peer.send(message) }
    }

    private func handle(_ message: Message, _ payload: Data, from peer: PeerConnection) {
        switch message {
        case let .hello(name, role, _):
            // The phone opens a second connection just for take files.
            guard role != "files" else { return }
            phoneName = name
            peer.send(.session(name: sessionName, nextTake: nextTakeNumber(for: sessionName)))
        case let .takeInfo(info):
            receive(info, from: peer)
        case let .chunk(id, offset):
            receiveChunk(id, offset: offset, data: payload, from: peer)
        case let .status(status):
            phoneStatus = status
        case .preview:
            if let image = NSImage(data: payload) { preview = image }
        default:
            break
        }
    }

    // MARK: - Takes

    private func index(_ id: UUID) -> Int? {
        takes.firstIndex { $0.id == id }
    }

    private func receive(_ incoming: TakeInfo, from peer: PeerConnection) {
        if let i = index(incoming.id) {
            var info = incoming
            info.session = takes[i].info.session
            let goodChanged = takes[i].info.good != info.good || takes[i].info.trimEnd != info.trimEnd
            takes[i].info = info
            if takes[i].saved {
                if goodChanged { applyGood(info.id) }
                peer.send(.takeStatus(id: info.id, have: takes[i].have, saved: true))
                persist()
                return
            }
        } else {
            var info = incoming
            if info.session.isEmpty { info.session = sessionName }
            let incomingDir = sessionDirectory(for: info.session).appendingPathComponent(".incoming", isDirectory: true)
            try? FileManager.default.createDirectory(at: incomingDir, withIntermediateDirectories: true)
            let partial = incomingDir.appendingPathComponent(info.id.uuidString + ".mov")
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            takes.insert(ReceivedTake(info: info, partialPath: partial.path), at: 0)
        }
        guard let i = index(incoming.id) else { return }
        if !FileManager.default.fileExists(atPath: takes[i].partialPath) {
            let url = URL(fileURLWithPath: takes[i].partialPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            takes[i].have = 0
        }
        if takes[i].info.finished {
            if takes[i].have >= takes[i].info.totalBytes {
                finalize(incoming.id)
            } else {
                peer.send(.takeStatus(id: incoming.id, have: takes[i].have, saved: false))
            }
        }
        persist()
    }

    private func receiveChunk(_ id: UUID, offset: Int64, data: Data, from peer: PeerConnection) {
        guard let i = index(id), !takes[i].saved, !finalizing.contains(id) else { return }
        // Only accept bytes that continue (or overlap) what we have; a gap is filled later.
        guard offset <= takes[i].have else { return }
        guard let handle = handle(for: takes[i]) else { return }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            takes[i].problem = "Couldn't write: \(error.localizedDescription)"
            return
        }
        takes[i].have = max(takes[i].have, offset + Int64(data.count))
        if takes[i].info.finished && takes[i].have >= takes[i].info.totalBytes {
            finalize(id)
        }
    }

    private func handle(for take: ReceivedTake) -> FileHandle? {
        if let existing = handles[take.id] { return existing }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: take.partialPath)) else { return nil }
        handles[take.id] = handle
        return handle
    }

    private func closeHandle(_ id: UUID) {
        if let handle = handles.removeValue(forKey: id) { try? handle.close() }
    }

    private func closeAllHandles() {
        for handle in handles.values { try? handle.close() }
        handles.removeAll()
    }

    /// The iPhone sends a complete QuickTime movie; file it as-is (no conversion), then check
    /// it really has sound and how long it is.
    private func finalize(_ id: UUID) {
        guard let i = index(id), !takes[i].saved, !finalizing.contains(id) else { return }
        finalizing.insert(id)
        closeHandle(id)
        let take = takes[i]
        let partial = URL(fileURLWithPath: take.partialPath)
        let allDir = sessionDirectory(for: take.info.session).appendingPathComponent("All Takes", isDirectory: true)
        try? FileManager.default.createDirectory(at: allDir, withIntermediateDirectories: true)

        if take.info.totalBytes == 0 {
            finishFinalize(id, finalURL: nil, problem: "The iPhone didn't record anything for this take.")
            try? FileManager.default.removeItem(at: partial)
            return
        }

        let destination = Self.uniqueURL(in: allDir, name: take.info.displayName, ext: "mov")
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            finishFinalize(id, finalURL: nil, problem: "Couldn't save: \(error.localizedDescription)")
            return
        }
        finishFinalize(id, finalURL: destination, problem: nil)
        Task {
            let check = await Remux.inspect(destination)
            await MainActor.run {
                guard let j = self.index(id) else { return }
                if check.duration > 0 { self.takes[j].info.duration = check.duration }
                if !check.hasAudio { self.takes[j].problem = "No sound in this take — check the mic" }
                self.persist()
            }
        }
    }

    private func finishFinalize(_ id: UUID, finalURL: URL?, problem: String?) {
        finalizing.remove(id)
        guard let i = index(id) else { return }
        takes[i].saved = true
        takes[i].finalPath = finalURL?.path
        takes[i].problem = problem
        broadcast(.takeStatus(id: id, have: takes[i].have, saved: true))
        applyGood(id)
        persist()
    }

    private func applyGood(_ id: UUID) {
        guard let i = index(id), takes[i].saved, let finalPath = takes[i].finalPath, !filingGood.contains(id) else { return }
        let take = takes[i]
        if take.info.good, take.goodPath == nil {
            filingGood.insert(id)
            let goodDir = sessionDirectory(for: take.info.session).appendingPathComponent("Good Takes", isDirectory: true)
            try? FileManager.default.createDirectory(at: goodDir, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: finalPath)
            let destination = Self.uniqueURL(in: goodDir, name: take.info.displayName, ext: source.pathExtension)
            var end: Double?
            if let trim = take.info.trimEnd, trim > 0.5, take.info.duration == 0 || trim < take.info.duration - 0.2 {
                end = trim
            }
            Task {
                var ok = false
                if let end, destination.pathExtension == "mov" {
                    ok = await Remux.export(from: source, to: destination, end: end)
                }
                if !ok {
                    ok = (try? FileManager.default.copyItem(at: source, to: destination)) != nil
                }
                let filed = ok
                await MainActor.run {
                    self.filingGood.remove(id)
                    guard let j = self.index(id) else { return }
                    if filed { self.takes[j].goodPath = destination.path }
                    self.persist()
                    // It may have been un-kept while we were copying.
                    if !self.takes[j].info.good { self.applyGood(id) }
                }
            }
        } else if !take.info.good, let goodPath = take.goodPath {
            try? FileManager.default.removeItem(atPath: goodPath)
            takes[i].goodPath = nil
        }
    }

    // MARK: - Files

    private func sessionDirectory(for session: String) -> URL {
        let safe = session
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rootURL.appendingPathComponent(safe.isEmpty ? "Untitled Session" : safe, isDirectory: true)
    }

    private func nextTakeNumber(for session: String) -> Int {
        (takes.filter { $0.info.session == session }.map(\.info.number).max() ?? 0) + 1
    }

    private static func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        var url = dir.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    private static func newSessionName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Session \(formatter.string(from: Date()))"
    }

    private func loadTakes() {
        guard let data = try? Data(contentsOf: storeURL),
              var loaded = try? JSONDecoder().decode([ReceivedTake].self, from: data) else { return }
        for i in loaded.indices where !loaded[i].saved {
            let size = (try? FileManager.default.attributesOfItem(atPath: loaded[i].partialPath)[.size] as? NSNumber)?.int64Value ?? 0
            loaded[i].have = size
        }
        takes = loaded
    }

    private func persist() {
        if takes.count > 1000 { takes.removeLast(takes.count - 1000) }
        if let data = try? JSONEncoder().encode(takes) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}

enum Remux {
    /// Real duration of a movie and whether it has a sound track.
    static func inspect(_ url: URL) async -> (duration: Double, hasAudio: Bool) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        return (duration.isFinite ? duration : 0, !audio.isEmpty)
    }

    /// Passthrough export (no quality loss). `end` trims the take at that many seconds.
    static func export(from source: URL, to destination: URL, end: Double?) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        session.outputURL = destination
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false
        if let end {
            session.timeRange = CMTimeRange(start: .zero, end: CMTime(seconds: end, preferredTimescale: 600))
        }
        return await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                let ok = session.status == .completed
                if !ok { try? FileManager.default.removeItem(at: destination) }
                continuation.resume(returning: ok)
            }
        }
    }
}
#endif
