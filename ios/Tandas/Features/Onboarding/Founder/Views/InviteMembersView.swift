import SwiftUI

struct InviteMembersView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var contactsPresented = false
    @State private var manualEntryPresented = false

    var body: some View {
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            stepCount: FounderStep.allCases.count,
            title: "Invita a tu grupo",
            subtitle: "Mínimo 3 personas para empezar.",
            primaryCTA: ("Continuar", coord.isLoading, { Task { await coord.advanceFromInvite() } }),
            secondaryCTA: ("Saltar", { Task { await coord.skipInvite() } }),
            canContinue: true
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
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
        Double(FounderStep.invite.index) / Double(FounderStep.allCases.count - 1)
    }

    private func shareLinkCard(group: Group) -> some View {
        let message = InviteLinkGenerator.shareMessage(groupName: group.name, code: group.inviteCode)
        return ShareLink(item: message) {
            HStack(spacing: RuulSpacing.s4) {
                RuulIconBadge("link", size: .medium)
                VStack(alignment: .leading, spacing: 2) {
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
            }
            .padding(RuulSpacing.s4)
            .ruulGlass(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous),
                material: .regular,
                interactive: true
            )
        }
        .buttonStyle(.ruulPress)
    }

    private var pendingList: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("Por invitar (\(coord.pendingInvites.count))")
                .ruulTextStyle(RuulTypography.footnote)
                .foregroundStyle(Color.ruulTextSecondary)
            VStack(spacing: 0) {
                ForEach(coord.pendingInvites) { pending in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
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
                                .foregroundStyle(Color.ruulSemanticSuccess)
                        } else {
                            Button { remove(pending) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.ruulTextTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, RuulSpacing.s2)
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
            VStack(spacing: RuulSpacing.s3) {
                RuulTextField("Nombre (opcional)", text: $manualName, label: "Nombre")
                RuulPhoneField(text: $manualPhone, label: "Teléfono")
            }
        }
    }
}
