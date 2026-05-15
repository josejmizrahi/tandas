import SwiftUI
import RuulUI
import RuulCore

public struct InviteWelcomeView: View {
    @Environment(InvitedOnboardingCoordinator.self) private var coord
    public var onDecline: () -> Void

    public init(onDecline: @escaping () -> Void) {
        self.onDecline = onDecline
    }

    public var body: some View {
        ZStack {
            ambientBackground
            content
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Tints the invite screen with the inviting group's cover palette
    /// (Luma signature). Falls back to the aqua mesh when the preview
    /// hasn't loaded yet so we never flash a black canvas.
    @ViewBuilder
    private var ambientBackground: some View {
        if let preview = coord.preview {
            let cover = RuulCoverCatalog.cover(named: preview.coverImageName)
            RuulAmbientBackground(palette: cover.palette, style: .vivid)
        } else {
            RuulMeshBackground(.aqua)
        }
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

    /// Tripsy-style invite layout: avatar stack → headline → poster card
    /// with embedded title+meta → primary CTA pill → secondary text button.
    /// The cover anchors visual weight in the middle of the screen so the
    /// invitation reads like a printed poster rather than a settings page.
    private func previewLayout(for preview: InvitePreview) -> some View {
        VStack(spacing: RuulSpacing.xl) {
            Spacer(minLength: RuulSpacing.lg)
            avatarStack(for: preview)
            headline(for: preview)
            posterCard(for: preview)
            Spacer(minLength: 0)
            actionStack
        }
        .padding(.horizontal, RuulSpacing.lg)
        .padding(.bottom, RuulSpacing.lg)
    }

    // MARK: - Avatar stack (top)

    @ViewBuilder
    private func avatarStack(for preview: InvitePreview) -> some View {
        let names = preview.recentMemberNames ?? []
        let people = names.prefix(5).enumerated().map { idx, name in
            RuulAvatarStack.Person(id: "\(idx)", name: name)
        }
        if !people.isEmpty {
            RuulAvatarStack(people: Array(people), size: .large, maxVisible: 5)
        } else {
            EmptyView()
        }
    }

    // MARK: - Headline

    private func headline(for preview: InvitePreview) -> some View {
        VStack(spacing: RuulSpacing.xs) {
            Text("Te invitan a unirte a")
                .ruulTextStyle(RuulTypography.bodyLarge)
                .foregroundStyle(.white.opacity(0.85))
            Text(preview.groupName)
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 4)
        }
    }

    // MARK: - Poster card

    /// The hero element: large rounded cover card with the group name and
    /// meta overlaid at the bottom over a dark fade. Mirrors the Tripsy
    /// travel-invite poster pattern.
    private func posterCard(for preview: InvitePreview) -> some View {
        let cover = RuulCoverCatalog.cover(named: preview.coverImageName)
        return ZStack(alignment: .bottomLeading) {
            RuulCoverView(cover)
            LinearGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.55)
                ],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                Text(preview.groupName)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(metaCopy(for: preview))
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(RuulSpacing.lg)
        }
        .aspectRatio(0.78, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.hero, style: .continuous))
        .ruulElevation(.lg)
    }

    private func metaCopy(for preview: InvitePreview) -> String {
        let count = preview.memberCount
        return "\(count) \(count == 1 ? "miembro" : "miembros")"
    }

    // MARK: - Action stack (bottom)

    private var actionStack: some View {
        VStack(spacing: RuulSpacing.sm) {
            Button {
                Task { await coord.acceptInvitation() }
            } label: {
                Text("Aceptar invitación")
                    .ruulTextStyle(RuulTypography.bodyLarge)
                    // Hardcoded black: paired with the hardcoded-white
                    // capsule below, this is the deliberate Tripsy-style
                    // "ready to commit" affordance — high-contrast pop
                    // regardless of light/dark theme. Don't swap for a
                    // semantic token; both colors are joined at the hip.
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 56)
                    .background(Capsule().fill(Color.white))
                    .ruulElevation(.sm)
            }
            .buttonStyle(.ruulPress)
            .accessibilityLabel("Aceptar invitación")

            Button(action: onDecline) {
                Text("Ahora no")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ahora no")
        }
    }
}
