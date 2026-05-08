import SwiftUI
import RuulUI
import RuulCore

/// Body component para `ResourceDetailView` cuando `resource.resourceType
/// == .event`. V1 duplica intencionalmente la estructura de
/// `EventDetailView` — esta última preserva su entry point existente
/// con su body bespoke. Cuando Phase 2 ship Slot resources y
/// ResourceDetailView se vuelve el router canonical, EventDetailView
/// se refactoriza a wrapping de EventDetailBody (audit follow-up).
///
/// V1 scope: scaffolding. No call sites V1 lo consumen.
struct EventDetailBody: View {
    @Bindable var coordinator: EventDetailCoordinator

    var body: some View {
        // V1: minimal stub. Phase 2 expands con structure real.
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            Text("Event detail body — Phase 2 will wire this up")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }
}
