import SwiftUI
import RuulUI

/// FASE 3 C.2 surface 2/3 — B.1 optimistic-toggle template applied to
/// inbox rows. A compact HStack of glass chips that lets the user resolve
/// a pending action in-place (RSVP, appeal vote, asset approval) without
/// pushing the matching detail screen.
///
/// Composition rules (per `feedback_dont_touch_ruului_base`):
///   - Lives in the feature layer; reuses RuulUI tokens + iOS 26 glass
///     button styles. No new primitives in RuulUI.
///   - Each action runs its own haptic + handler; the strip itself is
///     stateless so the row coordinator owns optimistic morph + revert.
///   - Glass styling: `.glass` + `.controlSize(.small)`. Destructive
///     chips carry `role: .destructive` (per `doctrine_button_styles`).
struct InlineActionStrip: View {
    struct Action: Identifiable {
        let id = UUID()
        let label: String
        let systemImage: String?
        let role: ButtonRole?
        let haptic: RuulHaptic
        let handler: () -> Void

        init(
            label: String,
            systemImage: String? = nil,
            role: ButtonRole? = nil,
            haptic: RuulHaptic = .medium,
            handler: @escaping () -> Void
        ) {
            self.label = label
            self.systemImage = systemImage
            self.role = role
            self.haptic = haptic
            self.handler = handler
        }
    }

    let actions: [Action]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions) { action in
                Button(role: action.role) {
                    action.haptic.trigger()
                    action.handler()
                } label: {
                    HStack(spacing: 6) {
                        if let symbol = action.systemImage {
                            Image(systemName: symbol)
                                .font(.footnote.weight(.semibold))
                        }
                        Text(action.label)
                            .font(.footnote.weight(.semibold))
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .buttonBorderShape(.capsule)
            }
            Spacer(minLength: 0)
        }
    }
}
