import Foundation
import Network

/// A framed message channel over one TCP connection.
/// Frame: [UInt32 JSON length][UInt32 payload length][JSON Message][payload bytes].
/// Callbacks arrive on the main queue. `send` may be called from any thread.
final class PeerConnection {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((Message, Data) -> Void)?
    var onClose: (() -> Void)?

    private let lock = NSLock()
    private var inFlight = 0
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Bytes handed to the network that haven't been sent yet.
    var bytesInFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
            case .failed, .cancelled, .waiting:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: .main)
        readNext()
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        connection.cancel()
        let handler = onClose
        onClose = nil
        onMessage = nil
        onReady = nil
        DispatchQueue.main.async { handler?() }
    }

    func send(_ message: Message, payload: Data = Data(), completion: ((Bool) -> Void)? = nil) {
        guard !isClosed, let json = try? JSONEncoder().encode(message) else {
            completion?(false)
            return
        }
        var frame = Data(capacity: 8 + json.count + payload.count)
        frame.appendUInt32(UInt32(json.count))
        frame.appendUInt32(UInt32(payload.count))
        frame.append(json)
        frame.append(payload)
        let size = frame.count
        lock.lock(); inFlight += size; lock.unlock()
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let self {
                self.lock.lock(); self.inFlight -= size; self.lock.unlock()
            }
            completion?(error == nil)
        })
    }

    private func readNext() {
        receive(exactly: 8) { [weak self] header in
            guard let self else { return }
            guard let header else { self.close(); return }
            let jsonLength = Int(header.readUInt32(at: 0))
            let payloadLength = Int(header.readUInt32(at: 4))
            guard jsonLength > 0, jsonLength < (1 << 20), payloadLength < (256 << 20) else {
                self.close()
                return
            }
            self.receive(exactly: jsonLength + payloadLength) { [weak self] body in
                guard let self else { return }
                guard let body else { self.close(); return }
                let start = body.startIndex
                let json = body.subdata(in: start ..< start + jsonLength)
                let payload = body.subdata(in: start + jsonLength ..< body.endIndex)
                if let message = try? JSONDecoder().decode(Message.self, from: json) {
                    self.onMessage?(message, payload)
                }
                self.readNext()
            }
        }
    }

    private func receive(exactly count: Int, _ done: @escaping (Data?) -> Void) {
        if count == 0 { done(Data()); return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if let data, data.count == count, error == nil {
                done(data)
            } else {
                done(nil)
            }
        }
    }
}
