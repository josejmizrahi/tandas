import SwiftUI
import RuulUI
import RuulCore

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
            RuulLoadingState()
        } else if coord.error == .inviteCodeInvalid {
            ErrorStateView(
                systemImage: "link.badge.plus",
                title: "Esta invitación ya no es válida",
                message: "Pídele a tu amigo que te mande una nueva.",
                retryAction: nil
            )
            .padding(RuulSpacing.lg)
        } else if let preview = coord.preview {
            previewLayout(for: preview)
        }
    }

    private func previewLayout(for preview: InvitePreview) -> some View {
        VStack(spacing: RuulSpacing.xxl) {
            Spacer()
            cover(for: preview)
            VStack(spacing: RuulSpacing.sm) {
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
            HStack(spacing: RuulSpacing.xs) {
                RuulButton("Ahorita no", style: .glass, size: .large, fillsWidth: true, action: onDecline)
                RuulButton("Unirme", style: .primary, size: .large, fillsWidth: true) {
                    Task { await coord.acceptInvitation() }
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.lg)
        }
    }

    private func cover(for preview: InvitePreview) -> some View {
        let cover = RuulCoverCatalog.cover(named: preview.coverImageName)
        return RuulCoverView(cover)
            .frame(height: RuulSize.heroBanner)
            .padding(.horizontal, RuulSpacing.lg)
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
