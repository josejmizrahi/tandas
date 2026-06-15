import SwiftUI
import RuulCore

// MARK: - Hero (R.10.E.8 — minimal critical-info-only, founder firmado 2026-06-15)
//
// R.10.E.8: el Hero post-Fase 9.3 mostraba 3 chips de counts (miembros /
// recursos / pendientes), TODOS duplicados en otras Sections post-E.5/E.6:
//   - Miembros count → footer de Section "Miembros" (E.1 avatars row)
//   - Recursos count → implícito en Section "Recursos" preview
//   - Pendientes → Attention Section + Decisiones Section
// Ahora: SÓLO mostrar 1 chip "X pendientes" en warning tint cuando hay
// trabajo actionable. Cero pendientes = Hero oculto = más espacio limpio
// para Sections de contenido real.
//
// Personal context: subtitle "Tu actividad, recursos y compromisos" se
// preserva ya que PersonalSpace no tiene Sections de duplicación.

struct ContextDetailV2HeroSection: View {
    let context: AppContext
    let descriptor: ContextDetailDescriptor

    var body: some View {
        let d = descriptor
        let pending = d.metrics.openObligations + d.metrics.pendingDecisions

        // Personal: chip subtitle siempre. Collective: sólo cuando hay pendientes.
        if context.isPersonal {
            personalHero
        } else if pending > 0 {
            collectivePendingHero(pending: pending)
        }
        // Si collective + 0 pendientes: Section oculta (espacio limpio).
    }

    @ViewBuilder
    private var personalHero: some View {
        Section {
            Text("Tu actividad, recursos y compromisos")
                .font(.caption)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func collectivePendingHero(pending: Int) -> some View {
        Section {
            Text("\(pending) \(pending == 1 ? "pendiente" : "pendientes")")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(Theme.Tint.warning)
                .background(Theme.Tint.warning.opacity(0.15), in: Capsule())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }
}
