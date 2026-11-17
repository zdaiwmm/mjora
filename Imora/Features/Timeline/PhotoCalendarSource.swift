import Foundation
import Observation
import SwiftUI

/// Calendar overviews always use capture dates. All retains its own ordering,
/// filter, rows and model identity; an upload-date index is never relabeled.
@MainActor
@Observable
final class PhotoCalendarSource {
    let gridModel: TimelineModel
    private let emptyModel: TimelineModel
    private var overviewModel: TimelineModel
    private(set) var isLoading = false
    private var lastError: String?
    var error: String? {
        if let context, !context.isActive { return String(localized: "The library session changed. Reopen the calendar overview.") }
        return lastError
    }
    @ObservationIgnored private var context: AccountRequestContext?
    private var hasBound = false
    private var isCancelled = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var monthTasks: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private var replaceAfterCancellation = false
    @ObservationIgnored private var requiresGridReplacement = false

    var model: TimelineModel {
        if requiresGridReplacement { return emptyModel }
        if let context, !context.isActive { return emptyModel }
        return overviewModel
    }
    var gridIdentity: ObjectIdentifier { ObjectIdentifier(gridModel) }
    private var ownsOverview: Bool { gridModel.filter.groupsByUploadDate }
    private var isDeviceProvided: Bool {
        gridModel.usesSuppliedAssets && !gridModel.flatAssets.isEmpty && gridModel.flatAssets.allSatisfy(\.isLocal)
    }

    init(gridModel: TimelineModel) {
        self.gridModel = gridModel
        var capture = gridModel.filter
        capture.orderBy = nil
        emptyModel = TimelineModel(filter: capture)
        overviewModel = gridModel.filter.groupsByUploadDate ? TimelineModel(filter: capture, mergesLocal: gridModel.mergesLocal) : gridModel
    }

    isolated deinit {
        loadTask?.cancel()
        monthTasks.values.forEach { $0.cancel() }
        if ownsOverview { overviewModel.suspendForViewer() }
    }

    func isBound(to client: ImoraClient?) -> Bool {
        hasBound && !isCancelled && context?.id == client?.context.id
    }

    func load(client: ImoraClient?, backup: BackupManager? = nil, hub: RealtimeHub? = nil, preferredAsset: Asset? = nil) async {
        guard !Task.isCancelled else { return }
        let reusesIndex = isBound(to: client) && !model.sections.isEmpty && loadTask == nil
        let nextContext = client?.context
        if requiresGridReplacement {
            context = nextContext; hasBound = true; isCancelled = false
            lastError = String(localized: "The library session changed. Reopen the calendar overview.")
            return
        }
        let changedAccount = hasBound && context?.id != nextContext?.id
        if changedAccount || replaceAfterCancellation {
            cancel()
            if ownsOverview { overviewModel = makeCaptureModel() }
            else if changedAccount && !isDeviceProvided {
                // A borrowed grid belongs to its original immutable account.
                // Its owner must replace it; never reattach it to another login.
                overviewModel = emptyModel
                requiresGridReplacement = true
                context = nextContext; hasBound = true; isCancelled = false
                lastError = String(localized: "The library session changed. Reopen the calendar overview.")
                return
            }
            replaceAfterCancellation = false
        }
        context = nextContext
        hasBound = true; isCancelled = false; lastError = nil
        guard nextContext?.isActive ?? gridModel.usesSuppliedAssets else {
            overviewModel = emptyModel
            lastError = String(localized: "Connect to your library to load capture dates.")
            return
        }
        if ownsOverview, gridModel.usesSuppliedAssets {
            // A supplied media/search selection keeps its existing predicates.
            // Regroup only those supplied assets, never broaden it to all media.
            if !overviewModel.usesSuppliedAssets { overviewModel = makeCaptureModel(supplied: true) }
            let assets = gridModel.flatAssets.sorted { $0.localDate < $1.localDate }
            overviewModel.replaceSuppliedAssets(assets, groupsByDate: true)
            synchronizeProjection()
            return
        }
        if !ownsOverview {
            overviewModel = gridModel
            if let preferredAsset, let id = Self.exactBucket(for: preferredAsset.id, in: model) ?? model.bucketID(containing: preferredAsset.localDate) {
                await model.loadBucket(id)
            }
            return
        }
        guard let client else { return }
        synchronizeProjection()
        overviewModel.resumeAfterViewer()
        overviewModel.attach(client, backup: backup, hub: hub)
        if reusesIndex { return }
        let target = overviewModel
        let ticket = generation
        let work: Task<Void, Never>
        if let current = loadTask, !current.isCancelled {
            work = current
        } else {
            isLoading = true
            work = Task { await target.load() }
            loadTask = work
        }
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard ticket == generation, context?.id == client.context.id else { return }
        isLoading = false
        loadTask = nil
        guard !Task.isCancelled, !work.isCancelled, client.context.isActive else { return }
        lastError = target.loadError
        if let preferredAsset,
           let id = Self.exactBucket(for: preferredAsset.id, in: target) ?? target.bucketID(containing: preferredAsset.localDate) {
            _ = await loadMonth(bucketIDs: [id])
        }
    }

    /// For callers that need an entire month, not merely a representative
    /// cover. The month UI can equivalently use model.loadBucket directly.
    func loadMonth(bucketIDs: [String]) async -> Bool {
        guard isUsable, !Task.isCancelled else { return false }
        let target = model, ticket = generation, taskID = UUID()
        var seen: Set<String> = []
        let ids = bucketIDs.filter { seen.insert($0).inserted }
        guard !ids.isEmpty, ids.allSatisfy({ id in target.sections.contains { $0.id == id } }) else { return false }
        let work = Task { @MainActor in
            for id in ids {
                guard !Task.isCancelled else { return false }
                await target.loadBucket(id)
                guard !Task.isCancelled, target.sections.first(where: { $0.id == id })?.isLoaded == true else { return false }
            }
            return true
        }
        monthTasks[taskID] = work
        defer { monthTasks.removeValue(forKey: taskID) }
        let complete = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        return complete && !Task.isCancelled && ticket == generation && isUsable && target === model
    }

    func synchronizeProjection() {
        guard ownsOverview, overviewModel !== emptyModel else { return }
        overviewModel.assetProjection = gridModel.assetProjection
    }

    func cancel() {
        generation = UUID()
        replaceAfterCancellation = replaceAfterCancellation || loadTask != nil
        loadTask?.cancel(); loadTask = nil
        monthTasks.values.forEach { $0.cancel() }; monthTasks.removeAll()
        if ownsOverview { overviewModel.suspendForViewer() }
        isLoading = false; isCancelled = true
    }

    func gridBucketID(for asset: Asset) -> String? {
        guard isUsable else { return nil }
        return Self.gridBucketID(for: asset, in: gridModel)
    }

    func gridRevealRequest(for asset: Asset) -> PhotoScrollRequest? {
        guard let bucket = gridBucketID(for: asset) else { return nil }
        return PhotoScrollRequest(bucketID: bucket, assetID: asset.id)
    }

    /// All may still use Date Added when leaving a capture-date day card.
    /// Exact loaded membership wins. Metadata fallback must use All's actual
    /// date field and an existing index entry, never the capture bucket ID.
    static func gridBucketID(for asset: Asset, in gridModel: TimelineModel) -> String? {
        if let exact = exactBucket(for: asset.id, in: gridModel) { return exact }
        if gridModel.filter.groupsByUploadDate {
            guard let createdAt = asset.createdAt else { return nil }
            // Remote Date Added indexes truncate createdAt in UTC. Device
            // wall-clock presentation must not shift an unloaded photo's bucket.
            return gridModel.bucketID(containing: createdAt)
        }
        return gridModel.bucketID(containing: asset.localDate)
    }

    private var isUsable: Bool {
        hasBound && !isCancelled && !requiresGridReplacement && (context?.isActive ?? gridModel.usesSuppliedAssets)
    }
    private static func exactBucket(for assetID: String, in model: TimelineModel) -> String? {
        model.sections.first { section in section.days?.contains { $0.assets.contains { $0.id == assetID } } == true }?.id
    }
    private func makeCaptureModel(supplied: Bool = false) -> TimelineModel {
        var capture = gridModel.filter; capture.orderBy = nil
        return TimelineModel(filter: capture, mergesLocal: gridModel.mergesLocal, suppliedAssets: supplied ? [] : nil)
    }
}

/// Owns the overview lifetime without changing TimelineScreen or the month
/// renderer. A new grid/account identity cannot briefly display an old index.
@MainActor
struct PhotoCalendarOverview: View {
    @Environment(SessionStore.self) private var session
    let gridModel: TimelineModel
    @Bindable var controls: PhotosGridControls
    let motion: PhotoPeriodMotion
    @State private var source: PhotoCalendarSource?

    nonisolated private struct RequestIdentity: Hashable, Sendable {
        let grid: ObjectIdentifier
        let account: UUID?
        let suppliedRevision: Int
        let isActive: Bool
    }
    private var requestIdentity: RequestIdentity {
        // Observe supplied selection changes even though the projection's
        // revision counter itself is intentionally ObservationIgnored.
        if gridModel.usesSuppliedAssets { _ = gridModel.flatAssets.count }
        return RequestIdentity(grid: ObjectIdentifier(gridModel), account: session.client?.context.id,
            suppliedRevision: gridModel.usesSuppliedAssets ? gridModel.rowsContentVersion : 0,
            isActive: controls.mode != .all)
    }

    var body: some View {
        Group {
            if controls.mode == .all {
                Color.clear
            } else {
                overview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(controls.mode == .all ? Color.clear : Color(.systemBackground))
        .allowsHitTesting(controls.mode != .all)
        .accessibilityHidden(controls.mode == .all)
        .task(id: requestIdentity) {
            if controls.mode != .all { await load() }
        }
        .onDisappear { source?.cancel() }
    }

    @ViewBuilder private var overview: some View {
        if let source, source.gridIdentity == ObjectIdentifier(gridModel), source.isBound(to: session.client) {
            if source.model.sections.isEmpty, let error = source.error ?? source.model.loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Capture Dates", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else if source.model.sections.isEmpty && (source.isLoading || source.model.isLoading) {
                ProgressView(String(localized: "Loading capture dates"))
            } else {
                PhotoPeriodsView(model: source.model, controls: controls, motion: motion)
            }
        } else {
            ProgressView(String(localized: "Loading capture dates"))
        }
    }

    private func load() async {
        if source?.gridIdentity != ObjectIdentifier(gridModel) {
            source?.cancel(); source = PhotoCalendarSource(gridModel: gridModel)
        }
        await source?.load(client: session.client, backup: session.backup, hub: session.realtime,
                           preferredAsset: controls.periodAnchor?.asset)
    }
}
