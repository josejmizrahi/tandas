//
//  ActivitySlot.swift
//  ResourceKit
//
//  Dispatcher + static + paginated entry points for the activity timeline
//  that lives at the bottom of every resource detail.
//

import SwiftUI
import RuulUI

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: ACTIVITY SLOT (con paginación)
// MARK: ════════════════════════════════════════════════════════════════════

struct ActivitySlot: View {
    let source: ActivitySource
    let accent: Color

    var body: some View {
        switch source {
        case .static(let items):
            ActivityStaticView(items: items, accent: accent)
        case .paginated(let loader):
            ActivityPaginatedView(loader: loader, accent: accent)
        }
    }
}

struct ActivityStaticView: View {
    let items: [ActivityItem]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            SectionHeader(title: "Actividad")
            if items.isEmpty {
                ActivityEmptyView()
            } else {
                ActivityGroupedTimeline(items: items, accent: accent)
            }
        }
    }
}

struct ActivityPaginatedView: View {
    let loader: ActivityLoader
    let accent: Color

    @State private var viewModel: ActivityViewModel

    init(loader: ActivityLoader, accent: Color) {
        self.loader = loader
        self.accent = accent
        self._viewModel = State(wrappedValue: ActivityViewModel(loader: loader))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            SectionHeader(title: "Actividad")

            switch viewModel.phase {
            case .idle, .loadingFirst:
                if viewModel.items.isEmpty {
                    ActivitySkeletonView()
                } else {
                    paginatedContent
                }
            case .error(let msg) where viewModel.items.isEmpty:
                ActivityErrorView(message: msg, accent: accent) { viewModel.loadFirst() }
            default:
                if viewModel.items.isEmpty {
                    ActivityEmptyView()
                } else {
                    paginatedContent
                }
            }
        }
        .onAppear { viewModel.loadInitialIfNeeded() }
    }

    private var paginatedContent: some View {
        VStack(spacing: 14) {
            ActivityGroupedTimeline(items: viewModel.items, accent: accent)

            if viewModel.hasMore {
                HStack(spacing: RuulSpacing.xs) {
                    if viewModel.phase == .loadingMore {
                        ProgressView().controlSize(.small)
                        Text("Cargando más…")
                            .font(.footnote).foregroundStyle(Color.ruulTextSecondary)
                    } else {
                        Color.clear.frame(height: 1)
                            .onAppear { viewModel.loadMore() }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, RuulSpacing.sm)
            }

            if case .error(let msg) = viewModel.phase, !viewModel.items.isEmpty {
                HStack(spacing: RuulSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.ruulSemanticWarning)
                    Text(msg).font(.footnote).foregroundStyle(Color.ruulTextSecondary)
                    Button("Reintentar") { viewModel.loadMore() }
                        .font(.footnote.weight(.semibold))
                        .tint(accent)
                }
                .padding(.vertical, RuulSpacing.xs)
            }
        }
    }
}
