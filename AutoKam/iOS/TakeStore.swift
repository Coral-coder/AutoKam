#if os(iOS)
import Foundation

struct LocalTake: Codable, Identifiable, Hashable {
    var info: TakeInfo
    var synced = false
    var fileDeleted = false
    var id: UUID { info.id }
}

/// Takes recorded on this iPhone, kept until the Mac confirms it saved them.
/// Files live in Documents/Takes (also visible in the Files app as a fallback).
final class TakeStore: ObservableObject {
    @Published private(set) var takes: [LocalTake] = []
    let directory: URL

    private var manifestURL: URL { directory.appendingPathComponent("takes.json") }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Takes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    var pendingCount: Int { takes.filter { !$0.synced && !$0.fileDeleted }.count }
    var lastTake: LocalTake? { takes.last }

    func fileURL(for id: UUID) -> URL {
        let mov = directory.appendingPathComponent(id.uuidString + ".mov")
        // Takes recorded by the first builds were .mp4.
        let legacy = directory.appendingPathComponent(id.uuidString + ".mp4")
        if !FileManager.default.fileExists(atPath: mov.path) && FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return mov
    }

    func take(_ id: UUID) -> LocalTake? {
        takes.first { $0.id == id }
    }

    func add(_ info: TakeInfo) {
        takes.append(LocalTake(info: info))
        save()
    }

    func update(_ info: TakeInfo) {
        guard let index = takes.firstIndex(where: { $0.id == info.id }) else { return }
        takes[index].info = info
        save()
    }

    func markSynced(_ id: UUID, deleteFile: Bool) {
        guard let index = takes.firstIndex(where: { $0.id == id }) else { return }
        takes[index].synced = true
        if deleteFile && !takes[index].fileDeleted {
            try? FileManager.default.removeItem(at: fileURL(for: id))
            takes[index].fileDeleted = true
        }
        save()
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        takes.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              var loaded = try? JSONDecoder().decode([LocalTake].self, from: data) else { return }
        // A take that was still recording when the app quit: send what was written.
        for i in loaded.indices where !loaded[i].info.finished {
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL(for: loaded[i].id).path)[.size] as? NSNumber)?.int64Value ?? 0
            loaded[i].info.finished = true
            loaded[i].info.totalBytes = size
        }
        takes = loaded
    }

    private func save() {
        // Keep the list bounded: forget old takes that are safely on the Mac.
        if takes.count > 300 {
            let excess = takes.count - 300
            var dropped = 0
            takes.removeAll { take in
                guard dropped < excess, take.synced else { return false }
                dropped += 1
                if !take.fileDeleted { try? FileManager.default.removeItem(at: fileURL(for: take.id)) }
                return true
            }
        }
        if let data = try? JSONEncoder().encode(takes) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }
}
#endif
