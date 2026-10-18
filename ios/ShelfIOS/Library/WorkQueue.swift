import Foundation

/// Ordered set of pending work keys with "do this one next" support.
///
/// Enrichment (duration, tags, covers) walks a library of hundreds or thousands of
/// files. Rows call `prioritize` as they appear, so what the user is looking at is
/// read first while the rest continues behind it.
struct WorkQueue<Key: Hashable> {
    private var order: [Key] = []
    private var members: Set<Key> = []

    var isEmpty: Bool { order.isEmpty }
    var count: Int { order.count }

    /// Appends a key at the back; ignored when already queued.
    mutating func enqueue(_ key: Key) {
        guard members.insert(key).inserted else { return }
        order.append(key)
    }

    mutating func enqueue<S: Sequence>(contentsOf keys: S) where S.Element == Key {
        for key in keys { enqueue(key) }
    }

    /// Moves a queued key to the front. Keys that are not queued are ignored, so a
    /// row can call this freely without re-adding finished work.
    mutating func prioritize(_ key: Key) {
        guard members.contains(key), let index = order.firstIndex(of: key), index > 0 else { return }
        order.remove(at: index)
        order.insert(key, at: 0)
    }

    mutating func popFirst() -> Key? {
        guard !order.isEmpty else { return nil }
        let key = order.removeFirst()
        members.remove(key)
        return key
    }

    mutating func removeAll() {
        order.removeAll()
        members.removeAll()
    }

    func contains(_ key: Key) -> Bool {
        members.contains(key)
    }
}
