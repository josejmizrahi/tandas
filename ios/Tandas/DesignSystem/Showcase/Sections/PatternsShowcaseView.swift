#if DEBUG
import SwiftUI

struct PatternsShowcaseView: View {
    @State private var rsvpState: EventCardData.RSVP = .notResponded

    var body: some View {
        ScrollView {
            VStack(spacing: RuulSpacing.s4) {
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
            .padding(RuulSpacing.s5)
        }
        .background(Color.ruulBackgroundCanvas)
    }

    private var emptyStateSection: some View {
        ShowcaseSection("EmptyStateView") {
            EmptyStateView(
                systemImage: "person.2",
                title: "Aún no hay miembros",
                message: "Comparte el código del grupo.",
                primaryAction: ("Compartir", { })
            )
        }
    }

    private var loadingStateSection: some View {
        ShowcaseSection("LoadingStateView") {
            VStack(spacing: RuulSpacing.s4) {
                LoadingStateView(.list)
                LoadingStateView(.card)
            }
        }
    }

    private var errorStateSection: some View {
        ShowcaseSection("ErrorStateView") {
            ErrorStateView(
                title: "Error de red",
                message: "Verifica tu conexión.",
                retryAction: ("Reintentar", { })
            )
        }
    }

    private var onboardingSection: some View {
        ShowcaseSection("OnboardingStepContainer") {
            OnboardingStepContainer(
                progress: 0.4,
                stepCount: 5,
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
            .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        }
    }

    private var eventCardSection: some View {
        ShowcaseSection("EventCardStub") {
            VStack(spacing: RuulSpacing.s3) {
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
            VStack(spacing: RuulSpacing.s3) {
                RuleCardStub(.init(id: "1", name: "Llegar tarde", description: "Más de 15 min.", amount: 50))
                RuleCardStub(.init(id: "2", name: "Pausada", amount: 25, isActive: false))
            }
        }
    }

    private var fineCardSection: some View {
        ShowcaseSection("FineCardStub") {
            VStack(spacing: RuulSpacing.s3) {
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
