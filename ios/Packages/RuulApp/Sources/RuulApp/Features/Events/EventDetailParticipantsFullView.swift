import SwiftUI
import RuulCore

// MARK: - Sheet: ver todos los participantes (agrupados por estado)
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo).

struct ParticipantsFullView: View {
    let participants: [EventParticipant]
    let store: EventDetailStore
    let canCheckInOthers: Bool
    let onCheckIn: (EventParticipant) -> Void
    // R.5Z.fix.EVENT.PARTICIPANTS (founder 2026-06-10) — edit mode params.
    let canManageRoster: Bool
    let myActorId: UUID?
    let eventId: UUID
    let rpc: any RuulRPCClient
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isShowingAdd = false
    @State private var isShowingAddGuest = false
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            ForEach(groups(), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.participants) { participant in
                        participantRow(participant)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if canManageRoster && participant.status != "cancelled" {
                                    Button(role: .destructive) {
                                        Task { await remove(participant) }
                                    } label: {
                                        Label("Remover", systemImage: "person.badge.minus")
                                    }
                                }
                            }
                    }
                }
            }
            // R.5Z.fix.EVENT.GUESTS — invitados externos (no members del contexto).
            if !store.guests.isEmpty {
                Section {
                    ForEach(store.guests) { guest in
                        guestRow(guest)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if canRemoveGuest(guest) {
                                    Button(role: .destructive) {
                                        Task { await removeGuest(guest) }
                                    } label: {
                                        Label("Remover", systemImage: "person.badge.minus")
                                    }
                                }
                            }
                    }
                } header: {
                    Text("Invitados externos")
                } footer: {
                    Text("Acompañantes que no son miembros del contexto. Cuentan en el split del gasto según su share.")
                }
            }
        }
        .navigationTitle("Participantes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if canManageRoster {
                        Button {
                            isShowingAdd = true
                        } label: {
                            Label("Agregar miembro", systemImage: "person.badge.plus")
                        }
                    }
                    Button {
                        isShowingAddGuest = true
                    } label: {
                        Label("Agregar invitado externo", systemImage: "person.crop.circle.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Agregar")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cerrar") { dismiss() }
            }
        }
        .actionErrorAlert(runner)
        .sheet(isPresented: $isShowingAdd, onDismiss: { onChanged() }) {
            AddParticipantsSheet(
                eventId: eventId,
                contextId: store.event?.contextActorId,
                existingActorIds: Set(
                    participants
                        .filter { $0.status != "cancelled" && $0.status != "declined" }
                        .map(\.participantActorId)
                ),
                rpc: rpc,
                onAdded: { onChanged() }
            )
        }
        .sheet(isPresented: $isShowingAddGuest, onDismiss: { onChanged() }) {
            AddEventGuestSheet(
                eventId: eventId,
                rpc: rpc,
                onAdded: { onChanged() }
            )
        }
    }

    @ViewBuilder
    private func guestRow(_ guest: EventGuest) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.title2)
                .foregroundStyle(Theme.Tint.primary)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(guest.displayName)
                    if guest.countShare > 1 {
                        Text("×\(guest.countShare)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.Tint.primary.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.Tint.primary)
                    }
                }
                if let invitedBy = guest.invitedByDisplayName {
                    Text("Invitado por \(invitedBy)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func canRemoveGuest(_ g: EventGuest) -> Bool {
        guard let myId = myActorId else { return false }
        return canManageRoster || g.invitedByActorId == myId
    }

    private func removeGuest(_ g: EventGuest) async {
        _ = await runner.run {
            try await rpc.removeEventGuest(guestId: g.id)
        }
        onChanged()
    }

    @ViewBuilder
    private func participantRow(_ participant: EventParticipant) -> some View {
        HStack(spacing: 12) {
            ActorInitialsView(name: store.displayName(for: participant.participantActorId), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(store.displayName(for: participant.participantActorId))
                    if participant.plusCount > 0 {
                        Text("+\(participant.plusCount)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.Tint.primary.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.Tint.primary)
                    }
                }
                Text(humanStatus(participant))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // R.5Z.fix.EVENT.PLUS_N — Stepper +N (self-service o admin).
            // Founder pidió +2/+N en lugar de bool +1. Cada unidad suma al
            // split. Range 0..20. Gate por status no terminal.
            if canEditPlusOne(participant)
                && participant.status != "cancelled"
                && participant.status != "declined" {
                HStack(spacing: 4) {
                    Stepper(value: Binding(
                        get: { participant.plusCount },
                        set: { newValue in
                            Task { await setPlusCount(participant, value: newValue) }
                        }
                    ), in: 0...20) {
                        Text(participant.plusCount > 0 ? "+\(participant.plusCount)" : "+0")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(participant.plusCount > 0 ? Theme.Tint.primary : Theme.Text.tertiary)
                            .frame(minWidth: 28)
                    }
                    .labelsHidden()
                    Text(participant.plusCount > 0 ? "+\(participant.plusCount)" : "")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.Tint.primary)
                }
            }
            // R.5Z.fix.EVENT.HOST_CONFIRM — host/admin puede marcar going.
            // Solo visible si el participant aún no está confirmado y no canceló.
            if canManageRoster
                && (participant.status == "invited" || participant.status == "maybe") {
                Button {
                    Task { await hostConfirm(participant) }
                } label: {
                    Image(systemName: "checkmark.seal")
                        .font(.title3)
                        .foregroundStyle(Theme.Tint.success)
                }
                .buttonStyle(.plain)
                .help("Confirmar por anfitrión")
            }
            if canCheckInOthers && !participant.checkedIn
                && participant.status != "cancelled"
                && participant.status != "declined" {
                Button {
                    onCheckIn(participant)
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func canEditPlusOne(_ p: EventParticipant) -> Bool {
        guard let myId = myActorId else { return false }
        return canManageRoster || p.participantActorId == myId
    }

    private func setPlusCount(_ p: EventParticipant, value: Int) async {
        _ = await runner.run {
            try await rpc.setEventParticipantPlusCount(
                eventId: eventId,
                actorId: p.participantActorId,
                count: value
            )
        }
        onChanged()
    }

    private func remove(_ p: EventParticipant) async {
        _ = await runner.run {
            try await rpc.removeEventParticipants(eventId: eventId, actorIds: [p.participantActorId])
        }
        onChanged()
    }

    private func hostConfirm(_ p: EventParticipant) async {
        _ = await runner.run {
            try await rpc.hostConfirmParticipant(eventId: eventId, actorId: p.participantActorId)
        }
        onChanged()
    }

    private struct ParticipantGroup {
        let title: String
        let participants: [EventParticipant]
    }

    private func groups() -> [ParticipantGroup] {
        let confirmed = participants.filter { $0.status == "going" || $0.status == "attended" || $0.checkedIn }
        let maybe = participants.filter { $0.status == "maybe" }
        let declined = participants.filter { $0.status == "declined" || $0.status == "cancelled" }
        let pending = participants.filter { $0.status == "invited" }
        let other = participants.filter { ["no_show", "late"].contains($0.status) }

        var out: [ParticipantGroup] = []
        if !confirmed.isEmpty { out.append(ParticipantGroup(title: "Confirmados", participants: confirmed)) }
        if !maybe.isEmpty     { out.append(ParticipantGroup(title: "Tal vez", participants: maybe)) }
        if !pending.isEmpty   { out.append(ParticipantGroup(title: "Sin respuesta", participants: pending)) }
        if !declined.isEmpty  { out.append(ParticipantGroup(title: "No asistirán", participants: declined)) }
        if !other.isEmpty     { out.append(ParticipantGroup(title: "Otros", participants: other)) }
        return out
    }

    private func humanStatus(_ p: EventParticipant) -> String {
        if p.checkedIn {
            if let minutes = p.minutesLate, minutes > 0 {
                return "Llegó \(Int(minutes)) min tarde"
            }
            return "Asistió"
        }
        switch p.status {
        case "going":     return "Confirmado"
        case "maybe":     return "Tal vez"
        case "declined":  return "No va"
        case "cancelled": return "Canceló"
        case "no_show":   return "No llegó"
        case "invited":   return "Sin respuesta"
        default:          return p.statusLabel
        }
    }
}
