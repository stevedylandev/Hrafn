import Foundation

/// A per-account lock shared across processes, so the app and the
/// notification service extension never hold a live session for the same
/// account at once (PLAN.md §2.5).
///
/// An advisory `flock` on a file in the App Group container. The kernel drops
/// it when the holder exits, so a crashed process cannot wedge the other.
///
/// iOS terminates a suspended app that holds a lock on a file in a shared
/// container (0xdead10cc): the app must release before it is suspended.
public final class AccountLock: @unchecked Sendable {

    public let url: URL
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    public init(directory: URL, accountID: String) {
        url = directory.appending(path: "\(accountID).lock")
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    public var isHeld: Bool { lock.withLock { descriptor >= 0 } }

    /// Takes the lock if nobody holds it. Idempotent for the holder.
    public func tryAcquire() -> Bool {
        lock.withLock {
            if descriptor >= 0 { return true }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return false }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                return false
            }
            descriptor = fd
            return true
        }
    }

    /// Waits up to `timeout` for the lock.
    public func acquire(timeout: Duration, poll: Duration = .milliseconds(200)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if tryAcquire() { return true }
            guard ContinuousClock.now + poll <= deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: poll)
        }
    }

    public func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
}
