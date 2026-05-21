//
//  ActivityViewModel.swift
//  ResourceKit
//
//  `@Observable` view model that drives the paginated activity timeline.
//  Owns the cursor + load Task. Cancellable in-flight requests, dedupes
//  by `ActivityItem.id` to survive overlapping pages.
//

import Foundation

@MainActor
@Observable
final class ActivityViewModel {
    private(set) var items: [ActivityItem] = []
    private(set) var phase: Phase = .idle
    private(set) var hasMore: Bool = true

    private var cursor: String?
    private let loader: ActivityLoader
    private var task: Task<Void, Never>?

    enum Phase: Equatable {
        case idle, loadingFirst, loadingMore, refreshing, loaded
        case error(String)
    }

    init(loader: ActivityLoader) { self.loader = loader }

    func loadInitialIfNeeded() {
        guard items.isEmpty, phase == .idle else { return }
        loadFirst()
    }

    func loadFirst() {
        task?.cancel()
        phase = .loadingFirst
        cursor = nil
        task = Task {
            do {
                let page = try await loader.load(cursor: nil)
                guard !Task.isCancelled else { return }
                items = page.items
                cursor = page.nextCursor
                hasMore = page.nextCursor != nil
                phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                phase = .error(error.localizedDescription)
            }
        }
    }

    func loadMore() {
        guard hasMore, phase != .loadingMore, phase != .loadingFirst, let cursor else { return }
        phase = .loadingMore
        task = Task {
            do {
                let page = try await loader.load(cursor: cursor)
                guard !Task.isCancelled else { return }
                let existing = Set(items.map(\.id))
                items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
                self.cursor = page.nextCursor
                hasMore = page.nextCursor != nil
                phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                phase = .error(error.localizedDescription)
            }
        }
    }
}
