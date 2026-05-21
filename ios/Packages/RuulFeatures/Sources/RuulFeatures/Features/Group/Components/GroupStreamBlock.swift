import SwiftUI
import RuulUI
import RuulCore

/// "Lo que pasa" — stream of recent group activity matching the
/// snippet's StreamCard. Each row = actor avatar (32pt) + composed
/// text "actor verb [amount] object" with colored amount, relative
/// time.
///
/// Data caveat: `MyActivityRepository` is per-user, so for V1 the
/// stream shows the *current user's* actions inside this group ("Tú
/// confirmaste asistencia"). When the backend exposes a group-wide
/// activity view, swap the data source and keep the row layout.
@MainActor
struct GroupStreamBlock: View {
    let items: [MyActivityItem]
    /// Current user's profile — used as the "actor" for every row,
    /// since `my_activity_v1` is scoped to the caller.
    let actor: Profile?
    let locale: String
    var onSeeAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack {
                Text("Lo que pasa")
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
                    row(item)
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

    private func row(_ item: MyActivityItem) -> some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            RuulAvatar(
                name: actorName,
                imageURL: actor?.avatarUrl.flatMap(URL.init(string:)),
                size: .small
            )

            VStack(alignment: .leading, spacing: 2) {
                streamText(item)
                Text(relativeTime(item.occurredAt))
                    .font(.caption2)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(RuulSpacing.md)
    }

    private var actorName: String {
        actor?.displayName ?? "Tú"
    }

    /// Composes a Text run with semibold actor + secondary verb +
    /// optional colored amount + object, mirroring the snippet's
    /// streamText helper.
    private func streamText(_ item: MyActivityItem) -> Text {
        let parts = Self.parts(for: item)
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

    // MARK: - Activity decoding

    /// `(verb, object, amount?)` parts extracted from a payload.
    struct Parts {
        let verb: String
        let object: String
        let amount: AmountPart?
    }

    struct AmountPart {
        let value: String
        let isPositive: Bool
    }

    static func parts(for item: MyActivityItem) -> Parts {
        switch item.kind {
        case .rsvp:
            if case .string(let s)? = item.payload["status"] {
                switch s {
                case "yes":      return Parts(verb: "confirmó", object: "asistencia", amount: nil)
                case "no":       return Parts(verb: "declinó", object: "asistencia", amount: nil)
                case "waitlist": return Parts(verb: "se unió a", object: "lista de espera", amount: nil)
                default: break
                }
            }
            return Parts(verb: "cambió", object: "su RSVP", amount: nil)

        case .checkIn:
            return Parts(verb: "hizo", object: "check-in", amount: nil)

        case .voteCast:
            if case .string(let s)? = item.payload["choice"] {
                switch s {
                case "in_favor":  return Parts(verb: "votó", object: "a favor", amount: nil)
                case "against":   return Parts(verb: "votó", object: "en contra", amount: nil)
                case "abstained": return Parts(verb: "se abstuvo", object: "", amount: nil)
                default: break
                }
            }
            return Parts(verb: "emitió", object: "un voto", amount: nil)

        case .ledger:
            let amount: AmountPart? = {
                if case .string(let s)? = item.payload["amount_display"] {
                    let isPositive = (item.payload["type"].flatMap { v -> String? in
                        if case .string(let kind) = v { return kind } else { return nil }
                    }) == "contribution"
                    return AmountPart(value: s, isPositive: isPositive)
                }
                return nil
            }()
            if case .string(let s)? = item.payload["type"] {
                switch s {
                case "fine_paid":    return Parts(verb: "pagó", object: "una multa", amount: amount)
                case "contribution": return Parts(verb: "aportó", object: "al fondo", amount: amount)
                case "expense":      return Parts(verb: "registró", object: "un gasto", amount: amount)
                default: break
                }
            }
            return Parts(verb: "registró", object: "un movimiento", amount: amount)
        }
    }
}
