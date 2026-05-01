import SwiftUI

struct InviteWelcomeView: View {
    @Environment(InvitedOnboardingCoordinator.self) private var coord
    var onDecline: () -> Void

    var body: some View {
        ZStack {
            RuulMeshBackground(.aqua)
            content
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var content: some View {
        if coord.isLoading {
            LoadingStateView(.detail)
                .padding(RuulSpacing.s5)
        } else if coord.error == .inviteCodeInvalid {
            ErrorStateView(
                systemImage: "link.badge.plus",
                title: "Esta invitación ya no es válida",
                message: "Pídele a tu amigo que te mande una nueva.",
                retryAction: nil
            )
            .padding(RuulSpacing.s5)
        } else if let preview = coord.preview {
            previewLayout(for: preview)
        }
    }

    private func previewLayout(for preview: InvitePreview) -> some View {
        VStack(spacing: RuulSpacing.s7) {
            Spacer()
            cover(for: preview)
            VStack(spacing: RuulSpacing.s3) {
                Text("Te invitaron a \(preview.groupName)")
                    .ruulTextStyle(RuulTypography.displayMedium)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .multilineTextAlignment(.center)
                Text(metaCopy(for: preview))
                    .ruulTextStyle(RuulTypography.bodyLarge)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.center)
            }
            avatarStack(for: preview)
            Spacer()
            HStack(spacing: RuulSpacing.s2) {
                RuulButton("Ahorita no", style: .glass, size: .large, fillsWidth: true, action: onDecline)
                RuulButton("Unirme", style: .primary, size: .large, fillsWidth: true) {
                    Task { await coord.acceptInvitation() }
                }
            }
            .padding(.horizontal, RuulSpacing.s5)
            .padding(.bottom, RuulSpacing.s5)
        }
    }

    private func cover(for preview: InvitePreview) -> some View {
        let cover = RuulCoverCatalog.cover(named: preview.coverImageName)
        return RuulCoverView(cover)
            .frame(height: RuulSize.heroBanner)
            .padding(.horizontal, RuulSpacing.s5)
    }

    private func metaCopy(for preview: InvitePreview) -> String {
        var pieces: [String] = ["\(preview.memberCount) miembros"]
        if !preview.eventLabel.isEmpty {
            pieces.append(preview.eventLabel)
        }
        if let ft = preview.frequencyType, !ft.isEmpty {
            pieces.append(ft)
        }
        return pieces.joined(separator: " · ")
    }

    private func avatarStack(for preview: InvitePreview) -> some View {
        let names = preview.recentMemberNames ?? []
        let people = names.prefix(5).enumerated().map { idx, name in
            RuulAvatarStack.Person(id: "\(idx)", name: name)
        }
        return SwiftUI.Group {
            if !people.isEmpty {
                RuulAvatarStack(people: Array(people), size: .large, maxVisible: 5)
            } else {
                EmptyView()
            }
        }
    }
}
