import Foundation
import PlinthModel

/// What the shell talks to. Runs one sync at a time, applies the merged result only if the
/// store did not change while the sync was running (otherwise it merges again), and debounces
/// bursts of local edits into one sync.
@MainActor public final class SyncCoordinator {
    public let engine: SyncEngine
    /// Wait after the last scheduled change before syncing.
    public var debounce: Duration

    public private(set) var isSyncing = false
    public private(set) var lastError: Error?
    public private(set) var otherDevices: [DeviceOpenPages] = []
    /// Called after each scheduled sync finishes.
    public var onSyncFinished: ((Result<[DeviceOpenPages], Error>) -> Void)?

    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var scheduled: Task<Void, Never>?
    /// Times a sync re-runs because the store changed during it, before giving up for now.
    static let maxRebases = 3

    public init(engine: SyncEngine, debounce: Duration = .seconds(5)) {
        self.engine = engine
        self.debounce = debounce
        self.otherDevices = engine.otherDevices()
    }

    /// Syncs now. `apply` is called with the merged state when something changed locally.
    /// If a sync is already running, waits for it and then syncs again.
    @discardableResult
    public func syncNow(local: () -> SyncPayload, openPages: () -> [OpenPageSummary],
                        apply: (SyncPayload) -> Void) async -> Result<[DeviceOpenPages], Error> {
        while isSyncing { await withCheckedContinuation { waiters.append($0) } }
        isSyncing = true
        defer {
            isSyncing = false
            let w = waiters
            waiters = []
            for c in w { c.resume() }
        }
        var result: Result<[DeviceOpenPages], Error> = .success(otherDevices)
        for _ in 0...Self.maxRebases {
            let snapshot = local()
            do {
                let outcome = try await engine.sync(local: snapshot, openPages: openPages())
                otherDevices = outcome.otherDevices
                lastError = nil
                result = .success(outcome.otherDevices)
                // Applying would overwrite edits made during the sync: merge again instead.
                guard local() == snapshot else { engine.mergeNotApplied(); continue }
                if let merged = outcome.merged { apply(merged) }
                break
            } catch {
                lastError = error
                result = .failure(error)
                break
            }
        }
        return result
    }

    /// Notes a local change and syncs after `debounce` of quiet. The closures are read when the
    /// sync runs, so they should read the live store.
    public func scheduleSync(local: @escaping () -> SyncPayload, openPages: @escaping () -> [OpenPageSummary],
                             apply: @escaping (SyncPayload) -> Void) {
        engine.recordLocalChanges(local())
        scheduled?.cancel()
        let delay = debounce
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let result = await self.syncNow(local: local, openPages: openPages, apply: apply)
            self.onSyncFinished?(result)
        }
    }

    /// Cancels a pending scheduled sync (a running one finishes).
    public func cancelScheduled() {
        scheduled?.cancel()
        scheduled = nil
    }
}
