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
            MeshBackground()
            VStack(spacing: Brand.Spacing.xl) {
                Spacer()
                VStack(spacing: Brand.Spacing.m) {
                    Text("¿Cómo te llaman?").font(.tandaHero).foregroundStyle(.white)
                    Text("Así te van a ver tus grupos.").font(.tandaBody).foregroundStyle(.white.opacity(0.7))
                }
                .multilineTextAlignment(.center)
                Field(label: "Tu nombre", error: errorMessage) {
                    TextField("Jose", text: $name)
                        .textContentType(.name)
                        .foregroundStyle(.white)
                        .font(.tandaTitle)
                }
                GlassCapsuleButton(isSubmitting ? "Guardando…" : "Continuar") {
                    Task { await submit() }
                }
                .disabled(!canSubmit)
                Spacer()
            }
            .padding(.horizontal, Brand.Spacing.xl)
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
