import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var name: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var feedback: Int = 0

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    var body: some View {
        ZStack {
            Brand.Surface.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Brand.Layout.sectionGap) {
                Spacer().frame(height: 80)
                VStack(alignment: .leading, spacing: 8) {
                    Text("¿Cómo te llaman?")
                        .font(Brand.Typography.heroTitle)
                        .foregroundStyle(Brand.Surface.textPrimary)
                    Text("Así te van a ver tus grupos.")
                        .font(Brand.Typography.body)
                        .foregroundStyle(Brand.Surface.textSecondary)
                }

                LumaField(label: "Tu nombre", error: errorMessage) {
                    TextField("Jose", text: $name)
                        .textContentType(.name)
                }

                Button {
                    Task { await submit() }
                } label: {
                    Text(isSubmitting ? "Guardando…" : "Continuar")
                        .frame(maxWidth: .infinity)
                        .lumaPrimaryPill()
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)

                Spacer()
            }
            .padding(.horizontal, Brand.Layout.pagePadH)
            .padding(.bottom, 32)
        }
        .sensoryFeedback(.success, trigger: feedback)
    }

    private func submit() async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { errorMessage = "Escribe tu nombre"; return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await app.profileRepo.updateDisplayName(clean)
            await app.refreshProfileAndGroups()
            feedback &+= 1
        } catch {
            errorMessage = "No se pudo guardar. Intenta de nuevo."
        }
    }
}
