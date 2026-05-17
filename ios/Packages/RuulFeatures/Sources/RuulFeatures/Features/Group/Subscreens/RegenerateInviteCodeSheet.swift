import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct RegenerateInviteCodeSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let groupId: UUID

    @State private var step: Step = .confirm
    @State private var newCode: String?
    @State private var rotating = false
    @State private var error: String?

    private enum Step { case confirm, success }

    public init(groupId: UUID) { self.groupId = groupId }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                switch step {
                case .confirm:
                    confirmStep
                case .success:
                    successStep
                }
            }
            .padding(RuulSpacing.lg)
            .ruulSheetToolbar(step == .confirm ? "Rotar código" : "Nuevo código")
        }
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("Esto invalidará el código actual. Los nuevos miembros usarán el nuevo código para unirse.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            if let error {
                Text(error)
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulNegative)
            }
            Spacer()
            Button { Task { await rotate() } } label: {
                if rotating {
                    ProgressView()
                } else {
                    Text("Rotar código")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(rotating)
        }
    }

    private var successStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("Tu nuevo código:")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            if let code = newCode {
                Text(code)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .padding(RuulSpacing.md)
                    .frame(maxWidth: .infinity)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
                ShareLink(item: "Únete a mi grupo: \(code)") {
                    Label("Compartir", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button("Listo") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func rotate() async {
        rotating = true
        error = nil
        defer { rotating = false }
        do {
            let code = try await app.groupsRepo.regenerateInviteCode(groupId: groupId)
            await app.refreshProfileAndGroups()
            self.newCode = code
            self.step = .success
        } catch {
            self.error = "No pudimos rotar el código. Verifica que tienes permisos."
        }
    }
}
