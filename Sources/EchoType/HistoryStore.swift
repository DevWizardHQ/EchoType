import Foundation

struct HistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let date: Date
    var pinned: Bool
}

/// All dictated transcripts, newest first, pinned items on top.
/// Persisted as JSON at ~/Library/Application Support/EchoType/history.json.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var items: [HistoryItem] = []

    /// Unpinned entries beyond this count are trimmed (oldest first).
    private let unpinnedCap = 500

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private let saveQueue = DispatchQueue(label: "echotype.history")

    private init() {
        load()
    }

    // MARK: - Mutations (main thread)

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(HistoryItem(id: UUID(), text: trimmed, date: Date(), pinned: false), at: 0)
        trim()
        sortAndSave()
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        sortAndSave()
    }

    func delete(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        sortAndSave()
    }

    /// Clear All keeps pinned items unless `includingPinned`.
    func clear(includingPinned: Bool) {
        items.removeAll { includingPinned || !$0.pinned }
        sortAndSave()
    }

    // MARK: - Internals

    /// Pinned first, then newest first within each group.
    private func sortAndSave() {
        items.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.date > rhs.date
        }
        save()
    }

    private func trim() {
        var unpinnedSeen = 0
        items = items.filter { item in
            if item.pinned { return true }
            unpinnedSeen += 1
            return unpinnedSeen <= unpinnedCap
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        let snapshot = items
        saveQueue.async { [url] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
