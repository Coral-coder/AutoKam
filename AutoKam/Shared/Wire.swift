import Foundation
import Network

/// Bonjour service the Mac advertises and the iPhone looks for.
enum AutoKamService {
    static let type = "_autokam._tcp"
    static let protocolVersion = 1

    /// TCP with keepalive, allowed over peer-to-peer Wi-Fi so the iPhone and Mac
    /// can find each other even without a shared network.
    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

enum HandGesture: String, Codable, CaseIterable {
    case openPalm, fist, thumbsUp, peace

    var emoji: String {
        switch self {
        case .openPalm: return "✋"
        case .fist: return "✊"
        case .thumbsUp: return "👍"
        case .peace: return "✌️"
        }
    }

    var meaning: String {
        switch self {
        case .openPalm: return "Start / goofed — redo this segment"
        case .fist: return "Cut — keep it and count in the next segment"
        case .thumbsUp: return "Keep this take and stop"
        case .peace: return "Stop (not kept)"
        }
    }
}

/// Everything both sides know about one take. The iPhone is the source of truth.
struct TakeInfo: Codable, Identifiable, Hashable {
    var id: UUID
    var number: Int
    var session: String
    var createdAt: Date
    var finished: Bool
    var totalBytes: Int64
    var duration: Double
    var good: Bool
    /// Seconds into the take where the "keep" gesture began; the good copy is cut there.
    var trimEnd: Double?
    /// The part of the video this take belongs to, and which try at it this is.
    var segment: Int? = nil
    var segmentTake: Int? = nil

    var displayName: String {
        if let segment, let segmentTake {
            return String(format: "Seg %02d - Take %02d", segment, segmentTake)
        }
        return String(format: "Take %03d", number)
    }
}

struct PhoneStatus: Codable, Hashable {
    var recording: Bool
    var takeNumber: Int
    var elapsed: Double
    var camera: String
    var resolution: String
    var gesture: String?
    var gestureProgress: Double
    var pendingUploads: Int
    var countdown: Int?
    var battery: Double?
    var micName: String? = nil
    var micExternal: Bool? = nil
    var warning: String? = nil
    var segment: Int? = nil
    var segmentTake: Int? = nil
    /// The last gesture that fired, and when (seconds since 1970).
    var lastGesture: String? = nil
    var lastGestureAt: Double? = nil
}

enum RemoteCommand: String, Codable {
    case record, stop, retake, keep, markLastGood, cut
}

enum Message: Codable {
    case hello(name: String, role: String, version: Int)
    /// Mac → iPhone: the session (folder) new takes go into and the next free take number.
    case session(name: String, nextTake: Int)
    /// iPhone → Mac: a take was created or changed.
    case takeInfo(TakeInfo)
    /// iPhone → Mac: bytes of a take's file at `offset` (payload).
    case chunk(id: UUID, offset: Int64)
    /// Mac → iPhone: how many contiguous bytes the Mac has, and whether the take is saved.
    case takeStatus(id: UUID, have: Int64, saved: Bool)
    case status(PhoneStatus)
    /// iPhone → Mac: a small JPEG of the camera view (payload).
    case preview
    case command(RemoteCommand)
}

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16) | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
