import SwiftUI
import RuulUI
import RuulCore

/// Apple Invites signature: a horizontal strip of attendee avatars with
/// names underneath. Compact enough to live above the fold inside the
/// detail page; the full per-status roll lives in `AttendeesListSheet`,
/// reached via the trailing "+N" / "Ver todos" affordance.
///
/// Visibility decisions:
///   - Show the first `maxVisible` (default 6) confirmed-going RSVPs
///     by `respondedAt` descending, so the strip stays under one line
///     of widths even on the largest dynamic-type setting.
///   - When there are more going attendees, append a "+N" badge tile
///     that opens the full list sheet on tap.
///   - Pendientes / no-vas surface in the full sheet only — keeps the
///     hero quiet.
///
/// Tapping any avatar invokes `onSelect` so the host can plumb it into
/// `MemberDetailView`.
public struct RSVPAvatarStrip: View {
    public let rsvps: [RSVP]
    public let memberDirectory: [UUID: MemberWithProfile]
    public let maxVisible: Int
    public let onSelectMember: (UUID) -> Void
    public let onSeeAll: () -> Void

    public init(
        rsvps: [RSVP],
        memberDirectory: [UUID: MemberWithProfile],
        maxVisible: Int = 6,
        onSelectMember: @escaping (UUID) -> Void,
        onSeeAll: @escaping () -> Void
    ) {
        self.rsvps = rsvps
        self.memberDirectory = memberDirectory
        self.maxVisible = maxVisible
        self.onSelectMember = onSelectMember
        self.onSeeAll = onSeeAll
    }

    public var body: some View {
        let going = goingRSVPs
        let visible = Array(going.prefix(maxVisible))
        let overflow = max(0, going.count - visible.count)

        if going.isEmpty {
            emptyState
        } else {
            Button(action: onSeeAll) {
                HStack(alignment: .top, spacing: RuulSpacing.md) {
                    ForEach(visible, id: \.id) { rsvp in
                        avatarTile(for: rsvp)
                    }
                    if overflow > 0 {
                        overflowTile(count: overflow)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, RuulSpacing.xxs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(going.count) personas confirmadas. Toca para ver la lista.")
        }
    }

    // MARK: - Tiles

    private func avatarTile(for rsvp: RSVP) -> some View {
        let profile = memberDirectory[rsvp.userId]
        let name = profile?.displayName ?? "Miembro"
        return VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RuulAvatar(name: name, imageURL: profile?.avatarURL, size: .medium)
                if rsvp.isCheckedIn {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.ruulPositive)
                        .padding(2)
                        .background(Color.ruulBackground, in: Circle())
                        .accessibilityHidden(true)
                }
            }
            Text(firstNameOnly(name))
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
                .lineLimit(1)
                .frame(maxWidth: 64)
        }
        .frame(width: 64)
        .onTapGesture { onSelectMember(rsvp.userId) }
        .accessibilityLabel(name)
        .accessibilityHint(rsvp.isCheckedIn ? "Ya llegó" : "Confirmado")
    }

    private func overflowTile(count: Int) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.ruulSurface)
                    .frame(width: 40, height: 40)
                Text("+\(count)")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            Text("Ver todos")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .frame(width: 64)
        .accessibilityLabel("\(count) personas más. Toca para ver la lista.")
    }

    private var emptyState: some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.ruulTextTertiary)
                .accessibilityHidden(true)
            Text("Sin confirmaciones aún")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    // MARK: - Helpers

    private var goingRSVPs: [RSVP] {
        rsvps
            .filter { $0.status == .going }
            .sorted { ($0.respondedAt ?? .distantPast) > ($1.respondedAt ?? .distantPast) }
    }

    private func firstNameOnly(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}
