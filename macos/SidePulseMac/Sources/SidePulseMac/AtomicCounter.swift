// AtomicCounter.swift — a counter the HTTP server can read off its own queue.
//
// `/health` is served on the network queue but reports a number the watcher
// increments on the main thread. Reaching back to the main actor from there is
// not an option: the request would have to block, and asserting main-actor
// isolation on a background queue is a hard crash, not a warning.

import Foundation

final class AtomicCounter: @unchecked Sendable {
    private var storage = 0
    private let lock = NSLock()

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
