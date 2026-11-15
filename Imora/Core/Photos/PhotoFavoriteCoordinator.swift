import Foundation
import Observation

nonisolated struct FavoriteMutationResult: Sendable {
    let localCommitted: Bool
    let syncPending: Bool
    let storageFailed: Bool
}

@MainActor @Observable
final class PhotoFavoriteCoordinator {
    typealias Write = @Sendable (String, Bool) async throws -> Void
    enum Failure: Error { case inactive, missingIdentity }
    let account: String
    private(set) var pendingCount = 0
    private(set) var syncFailed = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let store: FavoriteIntentStore
    @ObservationIgnored private let writeLocal: Write
    @ObservationIgnored private let writeRemote: Write
    @ObservationIgnored private var active = true
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var mutations: [String: (UUID, Task<FavoriteMutationResult, Error>)] = [:]

    init(account: String, store: FavoriteIntentStore = .shared,
         writeLocal: @escaping Write, writeRemote: @escaping Write) {
        self.account = account
        self.store = store
        self.writeLocal = writeLocal
        self.writeRemote = writeRemote
        pendingCount = store.pending(account: account).count
    }

    func start() {
        guard active, retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active else { return }
                await self.flush()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    func shutdown() {
        active = false
        retryTask?.cancel()
        retryTask = nil
    }

    func pendingValue(remoteID: String) -> Bool? {
        store.pending(account: account).first { $0.remoteID == remoteID }?.value
    }

    /// Device success is authoritative for the device. A server/network
    /// failure leaves a durable pending value instead of undoing PhotoKit.
    func set(localID: String?, remoteID: String?, value: Bool) async throws -> FavoriteMutationResult {
        guard active else { throw Failure.inactive }
        guard localID != nil || remoteID != nil else { throw Failure.missingIdentity }
        let identity = localID.map { "local:\($0)" } ?? "remote:\(remoteID!)"
        let previous = mutations[identity]?.1
        let operation = UUID()
        let mutation = Task {
            if let previous { _ = await previous.result }
            guard self.active else { throw Failure.inactive }
            return try await self.performSet(localID: localID, remoteID: remoteID, value: value)
        }
        mutations[identity] = (operation, mutation)
        defer {
            if mutations[identity]?.0 == operation { mutations[identity] = nil }
        }
        return try await mutation.value
    }

    private func performSet(localID: String?, remoteID: String?, value: Bool) async throws -> FavoriteMutationResult {
        if let localID { try await writeLocal(localID, value) }
        var storageFailed = false
        if let remoteID {
            do { try store.record(account: account, remoteID: remoteID, localID: localID, value: value) }
            catch {
                guard localID != nil else { throw error }
                storageFailed = true
            }
        }
        refreshStatus()
        if active { Task { [weak self] in await self?.flush() } }
        return FavoriteMutationResult(localCommitted: localID != nil,
            syncPending: remoteID != nil && !storageFailed, storageFailed: storageFailed)
    }

    func flush() async {
        guard active, !draining else { return }
        draining = true
        defer { draining = false; refreshStatus() }
        while active, !Task.isCancelled, let intent = store.pending(account: account).first {
            do {
                try await writeRemote(intent.remoteID, intent.value)
                guard active, !Task.isCancelled else { return }
                try store.acknowledge(intent)
                syncFailed = false
            } catch {
                syncFailed = true
                return
            }
        }
    }

    private func refreshStatus() {
        pendingCount = store.pending(account: account).count
        if active { onChange?() }
    }
}
