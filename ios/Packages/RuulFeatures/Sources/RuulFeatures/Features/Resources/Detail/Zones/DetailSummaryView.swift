import SwiftUI
import RuulUI
import RuulCore

/// "Summary" zone — a handful of key facts about the resource. Distinct
/// from the header (identity) and distinct from the dynamic sections
/// (deep data per capability). The rendered rows are declared by the
/// `SummaryFieldCatalog` keyed by `ResourceType`, so adding a new type
/// is a catalog edit, not a View edit. Audit fix for hard-coded per-type
/// switches inside the view layer.
public struct DetailSummaryView: View {
    public let context: ResourceDetailContext
    public let catalog: SummaryFieldCatalog

    public init(
        context: ResourceDetailContext,
        catalog: SummaryFieldCatalog = .v1
    ) {
        self.context = context
        self.catalog = catalog
    }

    public var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                sectionHeader("RESUMEN")
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.descriptor.id) { idx, row in
                        summaryRow(row)
                        if idx < rows.count - 1 { divider }
                    }
                }
                .cardBackground()
            }
        }
    }

    // MARK: - Row resolution

    private struct ResolvedRow {
        let descriptor: SummaryFieldDescriptor
        let value: String
    }

    /// Resolves descriptors for the resource's type into concrete rows,
    /// dropping any descriptor whose metadata is missing/empty. Order
    /// follows the catalog's declaration order.
    ///
    /// Builds a `SummaryResolverContext` from the resource metadata + a
    /// memberLookup closure that maps `auth.users.id` → display name
    /// via the cached `memberDirectory`. Required for descriptors that
    /// can only resolve through cross-references (today: the event
    /// host, which `events_view` ships as `host_id` only — no
    /// denormalized name).
    private var rows: [ResolvedRow] {
        let descriptors = catalog.fields(for: context.resource.resourceType)
        let directory = context.memberDirectory
        let resolverCtx = SummaryResolverContext(
            metadata: context.resource.metadata,
            memberLookup: { userId in
                directory[userId]?.displayName
            }
        )
        return descriptors.compactMap { d in
            guard let value = d.resolve(in: resolverCtx) else { return nil }
            return ResolvedRow(descriptor: d, value: value)
        }
    }

    // MARK: - Row UI

    private func summaryRow(_ row: ResolvedRow) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: row.descriptor.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ruulTextSecondary)
                .frame(width: 24)
            Text(row.descriptor.label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Text(row.value)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, 48)
    }
}
