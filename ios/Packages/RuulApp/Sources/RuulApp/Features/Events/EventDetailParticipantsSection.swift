import SwiftUI
import RuulCore

// MARK: - 3. Participantes (Section + avatar strip + breakdown)
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo).

struct EventDetailParticipantsSection: View {
    let store: EventDetailStore
    @Binding var isShowingAllParticipants: Bool

    var body: some View {
        if !store.participants.isEmpty {
            Section {
                Button {
                    isShowingAllParticipants = true
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        avatarStrip()
                        Text(participantBreakdown())
                            .font(.subheadline)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                // R.5Z.fix.EVENT.HEADER (founder 2026-06-10) — el header suma
                // base + plus_count + guests. Antes solo mostraba count de
                // participants ignorando los +N.
                Text("Participantes (\(totalPeopleCount))")
            }
        }
    }

    /// R.5Z.fix.EVENT.HEADER — total real de personas en el evento:
    /// participants (cada uno cuenta 1 + plus_count) + guests (sum de count_share).
    /// Solo considera participants no cancelled/declined.
    private var totalPeopleCount: Int {
        let participantsTotal = store.participants
            .filter { $0.status != "cancelled" && $0.status != "declined" }
            .reduce(0) { $0 + 1 + $1.plusCount }
        let guestsTotal = store.guests.reduce(0) { $0 + $1.countShare }
        return participantsTotal + guestsTotal
    }

    @ViewBuilder
    private func avatarStrip() -> some View {
        let preview = Array(store.participants.prefix(5))
        let extra = store.participants.count - preview.count

        HStack(spacing: -10) {
            ForEach(preview) { participant in
                ActorInitialsView(
                    name: store.displayName(for: participant.participantActorId),
                    size: 40
                )
                .overlay(
                    Circle().strokeBorder(Theme.Surface.card, lineWidth: 3)
                )
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.badgeFill, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Theme.Surface.card, lineWidth: 3)
                    )
            }
            Spacer(minLength: 0)
        }
    }

    /// "8 confirmados · 2 tal vez · 1 no asistirá".
    private func participantBreakdown() -> String {
        let confirmed = store.participants.filter {
            $0.status == "going" || $0.status == "attended" || $0.checkedIn
        }.count
        let maybe = store.participants.filter { $0.status == "maybe" }.count
        let declined = store.participants.filter { $0.status == "declined" }.count
        let pending = store.participants.filter { $0.status == "invited" }.count

        var parts: [String] = []
        if confirmed > 0 { parts.append("\(confirmed) \(confirmed == 1 ? "confirmado" : "confirmados")") }
        if maybe > 0     { parts.append("\(maybe) tal vez") }
        if declined > 0  { parts.append("\(declined) no \(declined == 1 ? "asistirá" : "asistirán")") }
        if pending > 0 && parts.isEmpty {
            parts.append("\(pending) sin respuesta")
        }
        return parts.isEmpty ? "Sin respuestas todavía" : parts.joined(separator: " · ")
    }
}
