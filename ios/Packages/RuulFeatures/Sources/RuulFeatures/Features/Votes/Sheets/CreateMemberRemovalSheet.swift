import SwiftUI
import RuulUI
import RuulCore

/// Sheet para crear una votación de tipo `.memberRemoval`. Pide al
/// creador elegir el miembro objetivo (o llega preseleccionado desde
/// MembersAdminView) y una razón de >= 30 caracteres, luego llama a
/// `CreateMemberRemovalCoordinator.submit()`.
@MainActor
public struct CreateMemberRemovalSheet: View {
    @Bindable var coordinator: CreateMemberRemovalCoordinator
    @Environment(\.dismiss) private var dismiss

    public init(coordinator: CreateMemberRemovalCoordinator) {
        self._coordinator = Bindable(wrappedValue: coordinator)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    warningCard
                    targetPicker
                    reasonInput
                    durationPicker

                    if let err = coordinator.error {
                        Text(err.message ?? err.title)
                            .font(.footnote)
                            .foregroundStyle(Color.ruulNegative)
                            .padding(.top, RuulSpacing.xs)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .ruulSheetToolbar("Proponer remoción")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(coordinator.isSubmitting ? "Enviando…" : "Iniciar voto") {
                        Task {
                            await coordinator.submit()
                            if coordinator.createdVoteId != nil { dismiss() }
                        }
                    }
                    .disabled(!coordinator.isReadyToSubmit || coordinator.isSubmitting)
                }
            }
            .task {
                if coordinator.members.isEmpty { await coordinator.loadMembers() }
            }
        }
    }

    // MARK: - Sections

    private var warningCard: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.ruulWarning)
                .accessibilityHidden(true)
            Text("Si el voto pasa, un fundador deberá ejecutar la remoción manualmente desde la pantalla de Miembros.")
                .font(.caption)
                .foregroundStyle(Color.ruulTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RuulSpacing.md)
        .background(
            Color.ruulSurface,
            in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
        )
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("A QUIEN")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ruulTextTertiary)

            if coordinator.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(RuulSpacing.md)
            } else if let selected = coordinator.target {
                // Confirmed target — tap to change.
                Button {
                    coordinator.target = nil
                } label: {
                    HStack(spacing: RuulSpacing.sm) {
                        RuulAvatar(name: selected.displayName, imageURL: selected.avatarURL, size: .medium)
                        Text(selected.displayName)
                            .font(.subheadline)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer()
                        Text("Cambiar")
                            .font(.caption)
                            .foregroundStyle(Color.ruulAccent)
                    }
                    .padding(RuulSpacing.md)
                    .background(
                        Color.ruulSurface,
                        in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            } else {
                // Picker menu when no target yet.
                Menu {
                    if coordinator.members.isEmpty {
                        Text("Sin miembros disponibles")
                    } else {
                        ForEach(coordinator.members) { m in
                            Button(m.displayName) { coordinator.target = m }
                        }
                    }
                } label: {
                    HStack {
                        Text("Elegir miembro")
                            .font(.subheadline)
                            .foregroundStyle(Color.ruulTextSecondary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.ruulTextTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(RuulSpacing.md)
                    .background(
                        Color.ruulSurface,
                        in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    )
                }
            }
        }
    }

    private var reasonInput: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("RAZON")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ruulTextTertiary)

            TextField("Por qué propones esta remoción…", text: $coordinator.reason, axis: .vertical)
                .lineLimit(4...8)
                .padding(RuulSpacing.md)
                .background(
                    Color.ruulSurface,
                    in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                )

            let charCount = coordinator.reason.trimmingCharacters(in: .whitespacesAndNewlines).count
            Text("Mínimo 30 caracteres — actual: \(charCount)")
                .font(.footnote)
                .foregroundStyle(charCount >= 30 ? Color.ruulTextTertiary : Color.ruulNegative)
        }
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("DURACION")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ruulTextTertiary)

            Picker("Duración", selection: $coordinator.durationHours) {
                Text("48 h").tag(48)
                Text("72 h").tag(72)
                Text("1 semana").tag(168)
            }
            .pickerStyle(.segmented)

            Text("El servidor puede sobrescribir este valor según la configuración del grupo.")
                .font(.footnote)
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }
}
