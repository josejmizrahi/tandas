import RuulUI
import RuulCore
#if DEBUG
import SwiftUI

struct PatternsShowcaseView: View {
    @State private var rsvpState: EventCardData.RSVP = .notResponded

    var body: some View {
        ScrollView {
            VStack(spacing: RuulSpacing.md) {
                emptyStateSection
                loadingStateSection
                errorStateSection
                onboardingSection
                memberRowSection
                eventCardSection
                rsvpSection
                ruleCardSection
                fineCardSection
            }
            .padding(RuulSpacing.lg)
        }
        .background(Color.ruulBackground)
    }

    private var emptyStateSection: some View {
        ShowcaseSection("ContentUnavailableView (empty)") {
            ContentUnavailableView {
                Label("Aún no hay miembros", systemImage: "person.2")
            } description: {
                Text("Comparte el código del grupo.")
            } actions: {
                Button("Compartir") { }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var loadingStateSection: some View {
        ShowcaseSection("RuulLoadingState") {
            VStack(spacing: RuulSpacing.md) {
                RuulLoadingState()
                    .frame(height: 120)
                RuulLoadingState(message: "Cargando…")
                    .frame(height: 120)
            }
        }
    }

    private var errorStateSection: some View {
        ShowcaseSection("ContentUnavailableView (error)") {
            ContentUnavailableView {
                Label("Error de red", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Verifica tu conexión.")
            } actions: {
                Button("Reintentar") { }
            }
        }
    }

    private var onboardingSection: some View {
        ShowcaseSection("OnboardingStepContainer") {
            OnboardingStepContainer(
                progress: 0.4,
                title: "Pregunta",
                subtitle: "Subtítulo",
                primaryCTA: ("Continuar", false, { })
            ) {
                RuulTextField("Demo", text: .constant(""))
            }
            .frame(height: 460)
        }
    }

    private var memberRowSection: some View {
        ShowcaseSection("MemberRowStub") {
            VStack(spacing: 0) {
                MemberRowStub(.init(id: "1", name: "Jose Mizrahi", subtitle: "admin", metaText: "$240"))
                Divider()
                MemberRowStub(.init(id: "2", name: "Ana Cohen", subtitle: "miembro", metaText: "$0"), trailingIcon: "chevron.right") {}
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
        }
    }

    private var eventCardSection: some View {
        ShowcaseSection("EventCardStub") {
            VStack(spacing: RuulSpacing.sm) {
                let attendees = (1...6).map { RuulAvatarStack.Person(id: "\($0)", name: "P\($0)") }
                EventCardStub(.init(
                    id: "1",
                    title: "Cena de los miércoles",
                    dateText: "Mié 7 may · 8:30 PM",
                    location: "Casa de Jose",
                    rsvp: .going,
                    attendees: attendees
                ))
                EventCardStub(.init(
                    id: "2",
                    title: "Brunch domingo",
                    dateText: "Dom 11 may · 11:00 AM",
                    location: nil,
                    rsvp: .notResponded,
                    attendees: []
                ))
            }
        }
    }

    private var rsvpSection: some View {
        ShowcaseSection("RSVPStateView") {
            RSVPStateView(state: rsvpState, onSelect: { rsvpState = $0 })
        }
    }

    private var ruleCardSection: some View {
        ShowcaseSection("RuleCardStub") {
            VStack(spacing: RuulSpacing.sm) {
                RuleCardStub(.init(id: "1", name: "Llegar tarde", description: "Más de 15 min.", amount: 50))
                RuleCardStub(.init(id: "2", name: "Pausada", amount: 25, isActive: false))
            }
        }
    }

    private var fineCardSection: some View {
        ShowcaseSection("FineCardStub") {
            VStack(spacing: RuulSpacing.sm) {
                FineCardStub(
                    .init(id: "1", reason: "Llegaste tarde", amount: 50, dateText: "Mié 7 may", status: .pending),
                    onPay: { },
                    onAppeal: { }
                )
                FineCardStub(.init(id: "2", reason: "RSVP cambiado", amount: 100, dateText: "Vie 2 may", status: .paid))
            }
        }
    }
}
#endif
