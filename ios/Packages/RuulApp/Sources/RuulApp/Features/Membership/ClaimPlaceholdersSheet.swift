import SwiftUI
import RuulCore

/// R.5W Slice 4 (2026-06-08) — Sheet welcoming que aparece al login cuando
/// hay placeholders con phone/email match. Pattern Apple Family Sharing:
/// la app reconoce que ya te invitaron, muestra dónde y te da consent
/// explícito para reclamar tu historia.
///
/// Founder caso: María agregó a su mamá como placeholder en Familia Mizrahi
/// con su teléfono. Cuando mamá instala Ruul y se registra con ese mismo
/// teléfono, este sheet aparece: "Hola! Te agregaron a Familia Mizrahi.
/// ¿Reclamar tu historia?" Tap → mamá entra con todas las invitaciones,
/// gastos y eventos que ya tenía pendientes.
struct ClaimPlaceholdersSheet: View {
    let matches: [PlaceholderMatch]
    let container: DependencyContainer
    let onDone: () -> Void

    @State private var runner = ActionRunner()
    @State private var claimedActorIds: Set<UUID> = []
    @State private var totalMemberships = 0
    @State private var totalObligations = 0
    @State private var totalEvents = 0
    @State private var showingSummary = false

    var body: some View {
        NavigationStack {
            if showingSummary {
                summaryView
            } else {
                introList
            }
        }
        .interactiveDismissDisabled(runner.isRunning)
    }

    // MARK: - Intro list

    @ViewBuilder
    private var introList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.Tint.primary)
                    Text("Te invitaron a Ruul")
                        .font(.title2.weight(.bold))
                    Text(introMessage)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Text.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(matches) { match in
                Section {
                    ForEach(match.contexts) { ctx in
                        HStack(spacing: 12) {
                            Image(systemName: contextIcon(ctx.contextActorSubtype))
                                .foregroundStyle(Theme.Tint.primary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ctx.contextDisplayName)
                                    .font(.callout.weight(.medium))
                                Text(contextSubtypeLabel(ctx.contextActorSubtype))
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                            Spacer()
                        }
                    }
                } header: {
                    Text("Como “\(match.displayName)”")
                } footer: {
                    // 7.C.4 (audit 2026-06-14) — copy conversacional sin
                    // "Match por" (jerga técnica).
                    if let phone = match.contactPhone {
                        Text("Te identificaron con tu teléfono \(phone).")
                    } else if let email = match.contactEmail {
                        Text("Te identificaron con tu correo \(email).")
                    }
                }
            }

            Section {
                Button {
                    Task { await claimAll() }
                } label: {
                    if runner.isRunning {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Reclamar tu historia", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(runner.isRunning)

                Button("Más tarde", role: .cancel) {
                    onDone()
                }
                .disabled(runner.isRunning)
            } footer: {
                // 7.C.4 — copy conversacional sin "heredar" (legal/técnico).
                Text("Si reclamas, se traen todos los gastos, eventos y compromisos que ya estaban a tu nombre. Si lo dejas para después, podrás hacerlo desde tu perfil.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Invitaciones pendientes")
        .navigationBarTitleDisplayMode(.inline)
        .actionErrorAlert(runner)
    }

    private var introMessage: String {
        let totalContexts = matches.reduce(0) { $0 + $1.contextCount }
        let names = matches.map { "“\($0.displayName)”" }.joined(separator: ", ")
        if matches.count == 1 {
            return "Alguien ya te agregó como \(names) en \(totalContexts == 1 ? "1 espacio" : "\(totalContexts) espacios") de Ruul. Reclama tu historia para empezar con todo dentro."
        }
        return "Tu teléfono o email aparece en \(matches.count) invitaciones. Reclamarlas hereda toda la historia que ya estaba a tu nombre."
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryView: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.Tint.success)
                        .symbolEffect(.bounce, value: showingSummary)
                    Text("¡Listo!")
                        .font(.title2.weight(.bold))
                    Text("Reclamaste tu historia. Ya tienes todo dentro.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Text.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                if totalMemberships > 0 {
                    LabeledContent("Membresías") {
                        Text("\(totalMemberships)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                    }
                }
                if totalObligations > 0 {
                    LabeledContent("Obligaciones") {
                        Text("\(totalObligations)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                    }
                }
                if totalEvents > 0 {
                    LabeledContent("Eventos") {
                        Text("\(totalEvents)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                    }
                }
            } header: {
                Text("Heredaste")
            }

            Section {
                Button {
                    onDone()
                } label: {
                    Label("Entrar", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Reclamado")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Actions

    private func claimAll() async {
        await runner.run {
            var totals = (memberships: 0, obligations: 0, events: 0)
            for match in matches where !claimedActorIds.contains(match.actorId) {
                let result = try await container.rpc.claimPlaceholderActor(
                    placeholderActorId: match.actorId
                )
                claimedActorIds.insert(match.actorId)
                totals.memberships += result.membershipsReassigned
                totals.obligations += result.obligationsReassigned
                totals.events += result.eventParticipantsReassigned
            }
            totalMemberships = totals.memberships
            totalObligations = totals.obligations
            totalEvents = totals.events
            showingSummary = true
        }
    }

    // MARK: - Subtype helpers

    private func contextIcon(_ subtype: String?) -> String {
        switch subtype {
        case "family":       return "house.fill"
        case "trip":         return "airplane"
        case "project":      return "rectangle.stack.fill"
        case "trust":        return "checkmark.shield.fill"
        case "community":    return "person.3.fill"
        case "friend_group": return "person.2.fill"
        case "company":      return "building.2.fill"
        default:             return "circle.grid.cross.fill"
        }
    }

    private func contextSubtypeLabel(_ subtype: String?) -> String {
        switch subtype {
        case "family":       return "Familia"
        case "community":    return "Comunidad"
        case "trip":         return "Viaje"
        case "project":      return "Proyecto"
        case "trust":        return "Fideicomiso"
        case "friend_group": return "Grupo"
        case "company":      return "Empresa"
        default:             return "Contexto"
        }
    }
}
