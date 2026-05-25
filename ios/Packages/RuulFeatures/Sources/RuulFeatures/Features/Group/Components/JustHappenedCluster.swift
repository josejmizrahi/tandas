import SwiftUI
import RuulUI
import RuulCore

/// "Acabó de pasar" — cluster #5 de la doctrina situacional. Reusa
/// el row recipe + `parts(for:)` decoder del antiguo
/// GroupStreamBlock. V1 data source: `my_activity_v1` filtrado por
/// grupo (per-user), igual que el bloque legacy — el día que un
/// feed group-wide aterrice, el row layout no cambia.
@MainActor
struct JustHappenedCluster: View {
    let items: [MyActivityItem]
    let actor: Profile?
    let locale: String
    var onSeeAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack {
                Text("Acabó de pasar")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                Spacer()
                if let onSeeAll {
                    Button("Ver todo", action: onSeeAll)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.ruulAccent)
                }
            }
            .padding(.horizontal, RuulSpacing.xxs)

            VStack(spacing: 0) {
                ForEach(items) { item in
                    JustHappenedRow(item: item, actor: actor, locale: locale)
                    if item.id != items.last?.id {
                        Divider()
                            .background(Color(.separator))
                            .padding(.leading, 54)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
    }
}

@MainActor
private struct JustHappenedRow: View {
    let item: MyActivityItem
    let actor: Profile?
    let locale: String

    var body: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            RuulAvatar(
                name: actorName,
                imageURL: actor?.avatarUrl.flatMap(URL.init(string:)),
                size: .small
            )

            VStack(alignment: .leading, spacing: 2) {
                streamText
                Text(relativeTime(item.occurredAt))
                    .font(.caption2)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(RuulSpacing.md)
    }

    private var actorName: String { actor?.displayName ?? "Tú" }

    private var streamText: Text {
        let parts = GroupStreamBlock.parts(for: item)
        var t = Text(actorName).fontWeight(.semibold)
            + Text(" \(parts.verb) ").foregroundColor(.secondary)
        if let amount = parts.amount {
            let amountText = Text(amount.value).fontWeight(.semibold)
            t = t + (amount.isPositive
                     ? amountText.foregroundColor(Color.ruulPositive)
                     : amountText.foregroundColor(Color.ruulNegative))
            t = t + Text(" ")
        }
        if !parts.object.isEmpty {
            t = t + Text(parts.object).foregroundColor(.primary)
        }
        return t.font(.subheadline)
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: locale)
        return f.localizedString(for: date, relativeTo: .now)
    }
}
