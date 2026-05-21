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
        Color(.systemBackground).ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        // `previewPhase` collapses `isLoading` + `preview` + `error` into
        // a single `LoadPhase`. AsyncContentView renders the standard
        // loading/error/loaded primitives — the only welcome-specific
        // wrinkle was the `.inviteCodeInvalid` copy, which now flows
        // through the `CoordinatorError.title` in `previewPhase`.
        AsyncContentView(
            phase: coord.previewPhase,
            onRetry: nil,
            loaded: { preview in previewLayout(for: preview) }
        )
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
                .font(.body)
                .foregroundStyle(Color.white.opacity(0.85))
            Text(preview.groupName)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .shadow(color: Color.black.opacity(0.18), radius: RuulSpacing.md, x: 0, y: 4)
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
                    Color.black.opacity(0.20).opacity(0),
                    Color.black.opacity(0.78)
                ],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                Text(preview.groupName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                Text(metaCopy(for: preview))
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(2)
                Text(vintageCopy(for: preview))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.85).opacity(0.85))
            }
            .padding(RuulSpacing.lg)
        }
        .aspectRatio(0.78, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.hero, style: .continuous))
    }

    /// Meta line del poster card. Antes era genérico "12 miembros";
    /// ahora prioriza social proof (nombres reales) cuando el preview
    /// los carga, fallback al count. P1 — el primer momento del
    /// invitado se siente más humano si ve "Miguel, Ana, Jose..."
    /// vs un número crudo.
    private func metaCopy(for preview: InvitePreview) -> String {
        if let names = preview.recentMemberNames, !names.isEmpty {
            let firstFew = names.prefix(3).joined(separator: ", ")
            let rest = preview.memberCount - min(3, names.count)
            if rest > 0 {
                return "\(firstFew) y \(rest) más"
            }
            return firstFew
        }
        let count = preview.memberCount
        return "\(count) \(count == 1 ? "miembro" : "miembros")"
    }

    /// "Activo desde mayo 2026" — agrega historial al poster para que
    /// el invitado entienda que entra a un grupo establecido, no uno
    /// recién creado.
    private func vintageCopy(for preview: InvitePreview) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_MX")
        formatter.dateFormat = "MMMM yyyy"
        return "Activo desde \(formatter.string(from: preview.groupCreatedAt))"
    }

    // MARK: - Action stack (bottom)

    private var actionStack: some View {
        VStack(spacing: RuulSpacing.sm) {
            Button {
                Task { await coord.acceptInvitation() }
            } label: {
                Text("Aceptar invitación")
                    .font(.body)
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 56)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.ruulPress)
            .accessibilityLabel("Aceptar invitación")

            Button(action: onDecline) {
                Text("Ahora no")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ahora no")
        }
    }
}
