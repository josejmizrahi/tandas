import SwiftUI
import RuulUI
import RuulCore

struct InviteMembersView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var contactsPresented = false
    @State private var manualEntryPresented = false

    var body: some View {
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            stepCount: FounderStep.visibleSteps.count,
            title: "Invita a tu grupo",
            subtitle: "Mínimo 3 personas para empezar.",
            primaryCTA: ("Continuar", coord.isLoading, { Task { await coord.advanceFromInvite() } }),
            secondaryCTA: ("Saltar", { Task { await coord.skipInvite() } }),
            canContinue: true
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                if let group = coord.createdGroup {
                    shareLinkCard(group: group)
                    RuulActionableCard(
                        icon: "person.crop.circle.badge.plus",
                        title: "Agregar por número",
                        subtitle: "Importa de contactos o escríbelo a mano.",
                        accessory: .badge("Recomendado")
                    ) {
                        contactsPresented = true
                    }
                    if !coord.pendingInvites.isEmpty {
                        pendingList
                    }
                }
            }
        }
        .ruulContactsPicker(isPresented: $contactsPresented) { picks in
            for pick in picks {
                if let e164 = PhoneFormatter.smartE164(pick.phoneRaw) {
                    coord.pendingInvites.append(
                        PendingInvite(phoneE164: e164, displayName: pick.name)
                    )
                }
            }
        }
        .ruulSheet(isPresented: $manualEntryPresented) {
            manualEntrySheet
        }
    }

    private var progressValue: Double {
        FounderStep.invite.progressFraction
    }

    private func shareLinkCard(group: RuulCore.Group) -> some View {
        let message = InviteLinkGenerator.shareMessage(groupName: group.name, code: group.inviteCode)
        return ShareLink(item: message) {
            HStack(spacing: RuulSpacing.md) {
                RuulIconBadge("link", size: .medium)
                VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                    Text("Compartir link")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text("Mándalo por WhatsApp, SMS, donde sea.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .background(
                Color.ruulSurface,
                in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
    }

    private var pendingList: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Por invitar (\(coord.pendingInvites.count))")
                .ruulTextStyle(RuulTypography.footnote)
                .foregroundStyle(Color.ruulTextSecondary)
            VStack(spacing: RuulSpacing.s0) {
                ForEach(coord.pendingInvites) { pending in
                    HStack {
                        VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                            if let name = pending.displayName {
                                Text(name)
                                    .ruulTextStyle(RuulTypography.body)
                                    .foregroundStyle(Color.ruulTextPrimary)
                                Text(PhoneFormatter.displayFormat(pending.phoneE164))
                                    .ruulTextStyle(RuulTypography.caption)
                                    .foregroundStyle(Color.ruulTextSecondary)
                            } else {
                                Text(PhoneFormatter.displayFormat(pending.phoneE164))
                                    .ruulTextStyle(RuulTypography.body)
                                    .foregroundStyle(Color.ruulTextPrimary)
                            }
                        }
                        Spacer()
                        if pending.sentAt != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.ruulPositive)
                                .accessibilityLabel("Invitación enviada")
                        } else {
                            Button { remove(pending) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.ruulTextTertiary)
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Quitar invitación")
                        }
                    }
                    .padding(.vertical, RuulSpacing.xs)
                    if pending.id != coord.pendingInvites.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func remove(_ invite: PendingInvite) {
        coord.pendingInvites.removeAll { $0.id == invite.id }
    }

    @State private var manualPhone = ""
    @State private var manualName = ""

    private var manualEntrySheet: some View {
        ModalSheetTemplate(
            title: "Agregar manual",
            dismissAction: { manualEntryPresented = false },
            primaryCTA: ("Agregar", {
                if let e164 = PhoneFormatter.smartE164(manualPhone) {
                    coord.pendingInvites.append(
                        PendingInvite(phoneE164: e164, displayName: manualName.isEmpty ? nil : manualName)
                    )
                    manualPhone = ""
                    manualName = ""
                    manualEntryPresented = false
                }
            })
        ) {
            VStack(spacing: RuulSpacing.sm) {
                RuulTextField("Nombre (opcional)", text: $manualName, label: "Nombre")
                RuulPhoneField(text: $manualPhone, label: "Teléfono")
            }
        }
    }
}
