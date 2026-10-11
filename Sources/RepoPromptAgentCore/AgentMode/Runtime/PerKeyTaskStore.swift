import Foundation

@MainActor
final class PerKeyTaskStore<Key: Hashable> {
    private var tasks: [Key: Task<Void, Never>] = [:]

    func hasTask(for key: Key) -> Bool {
        tasks[key] != nil
    }

    func set(_ key: Key, task: Task<Void, Never>) {
        if let existing = tasks.removeValue(forKey: key) {
            existing.cancel()
        }
        tasks[key] = task
    }

    func remove(_ key: Key) {
        _ = tasks.removeValue(forKey: key)
    }

    func cancel(_ key: Key) {
        guard let task = tasks.removeValue(forKey: key) else { return }
        task.cancel()
    }

    func cancelAll() {
        let activeTasks = tasks.values
        tasks.removeAll()
        for task in activeTasks {
            task.cancel()
        }
    }
}
