#if os(iOS)
import Foundation
import Network
import UIKit

/// Finds AutoKam Macs over Bonjour and keeps one connection open.
final class PhoneLink: ObservableObject {
    struct MacEndpoint: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var macs: [MacEndpoint] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var connectingName: String?
    @Published private(set) var preferredName: String?

    var onMessage: ((Message, Data) -> Void)?
    var onConnected: (() -> Void)?

    var isConnected: Bool { connectedName != nil }

    private var browser: NWBrowser?
    private var peer: PeerConnection?
    private let peerLock = NSLock()
    private var readyPeer: PeerConnection?

    init() {
        preferredName = UserDefaults.standard.string(forKey: "preferredMac")
    }

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: AutoKamService.type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.browser?.cancel()
                self?.browser = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.start() }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func choose(_ mac: MacEndpoint) {
        preferredName = mac.name
        UserDefaults.standard.set(mac.name, forKey: "preferredMac")
        peer?.close()
        peer = nil
        setReady(nil)
        connectedName = nil
        connectingName = nil
        connect(mac)
    }

    /// Thread-safe.
    func send(_ message: Message, payload: Data = Data(), completion: ((Bool) -> Void)? = nil) {
        guard let peer = currentReadyPeer() else {
            completion?(false)
            return
        }
        peer.send(message, payload: payload, completion: completion)
    }

    /// Thread-safe. Previews are skipped whenever anything else is waiting to go out.
    func sendPreview(_ jpeg: Data) {
        guard let peer = currentReadyPeer(), peer.bytesInFlight < 1 << 20 else { return }
        peer.send(.preview, payload: jpeg)
    }

    var hasReadyPeer: Bool { currentReadyPeer() != nil }

    // MARK: - Private

    private func currentReadyPeer() -> PeerConnection? {
        peerLock.lock(); defer { peerLock.unlock() }
        return readyPeer
    }

    private func setReady(_ peer: PeerConnection?) {
        peerLock.lock(); readyPeer = peer; peerLock.unlock()
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        var list: [MacEndpoint] = []
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint, !seen.contains(name) {
                seen.insert(name)
                list.append(MacEndpoint(name: name, endpoint: result.endpoint))
            }
        }
        macs = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        autoConnect()
    }

    private func autoConnect() {
        guard peer == nil else { return }
        let target = macs.first { $0.name == preferredName } ?? macs.first
        if let target { connect(target) }
    }

    private func connect(_ mac: MacEndpoint) {
        let connection = NWConnection(to: mac.endpoint, using: AutoKamService.tcpParameters())
        let newPeer = PeerConnection(connection)
        peer = newPeer
        connectingName = mac.name

        newPeer.onReady = { [weak self, weak newPeer] in
            guard let self, let newPeer, self.peer === newPeer else { return }
            self.connectingName = nil
            self.connectedName = mac.name
            self.setReady(newPeer)
            newPeer.send(.hello(name: UIDevice.current.name, role: "camera", version: AutoKamService.protocolVersion))
            self.onConnected?()
        }
        newPeer.onMessage = { [weak self] message, payload in
            self?.onMessage?(message, payload)
        }
        newPeer.onClose = { [weak self, weak newPeer] in
            guard let self, self.peer === newPeer else { return }
            self.peer = nil
            self.setReady(nil)
            self.connectedName = nil
            self.connectingName = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.autoConnect() }
        }
        newPeer.start()

        // A stale Bonjour entry can leave a connection hanging; give up and retry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak newPeer] in
            guard let self, let newPeer, self.peer === newPeer, self.connectedName == nil else { return }
            newPeer.close()
        }
    }
}
#endif
