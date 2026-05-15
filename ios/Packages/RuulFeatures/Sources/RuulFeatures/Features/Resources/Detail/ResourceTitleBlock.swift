import SwiftUI
import RuulCore
import RuulUI

/// Magazine-style title block that sits below the cover hero and above
/// the capability sections. Mirrors the Luma / Apple Invites identity
/// zone: a clean stack of when + who's hosting — the facts a guest needs
/// at a glance — without the cover's white-on-color overlay tradeoffs.
///
/// Location lives below in `LocationSectionView` (full map card), so this
/// block stays focused on the time and host attribution.
///
/// Renders rows only for facts we actually have. If none of the rows
/// resolve, the whole view collapses to `EmptyView` so the panel keeps
/// its rhythm even on data-sparse resources.
@MainActor
public struct ResourceTitleBlock: View {
    public let context: ResourceDetailContext
    public let startsAt: Date?
    public let endsAt: Date?

    public init(
        context: ResourceDetailContext,
        startsAt: Date?,
        endsAt: Date?
    ) {
        self.context = context
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    public var body: some View {
        if hasAnyRow {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                if let dateLine {
                    row(
                        symbol: "calendar",
                        title: dateLine,
                        subtitle: timeLine
                    )
                }
                if let host = hostRow {
                    hostRowView(host)
                }
            }
            .padding(.horizontal, RuulSpacing.s6)
        }
    }

    // MARK: - Rows

    private func row(symbol: String, title: String, subtitle: String?) -> some View {
        HStack(alignment: .center, spacing: RuulSpacing.md) {
            iconBadge(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let subtitle {
                    Text(subtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func hostRowView(_ host: MemberWithProfile) -> some View {
        HStack(alignment: .center, spacing: RuulSpacing.md) {
            RuulAvatar(
                name: host.displayName,
                imageURL: host.avatarURL,
                size: .small
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Anfitrión")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func iconBadge(symbol: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.ruulSurface)
                .frame(width: 32, height: 32)
            Image(systemName: symbol)
                .ruulTextStyle(RuulTypography.calloutRegular)
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }

    // MARK: - Derived facts

    private var hasAnyRow: Bool {
        dateLine != nil || hostRow != nil
    }

    /// Human-friendly day phrase: "Hoy", "Mañana", "Jueves 15 de mayo".
    /// Falls back to the short date when relative phrasing isn't useful.
    private var dateLine: String? {
        guard let startsAt else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(startsAt) { return "Hoy" }
        if cal.isDateInTomorrow(startsAt) { return "Mañana" }
        return startsAt.ruulFullDate
    }

    /// "8:30 a.m. – 10:30 a.m." when we have both ends, otherwise just
    /// the start time. Nil if no start time at all.
    private var timeLine: String? {
        guard let startsAt else { return nil }
        let start = startsAt.ruulShortTime
        if let endsAt {
            return "\(start) – \(endsAt.ruulShortTime)"
        }
        return start
    }

    private var hostRow: MemberWithProfile? {
        guard let raw = context.resource.metadata["host_id"]?.stringValue,
              let id = UUID(uuidString: raw) else { return nil }
        return context.memberDirectory[id]
    }
}
