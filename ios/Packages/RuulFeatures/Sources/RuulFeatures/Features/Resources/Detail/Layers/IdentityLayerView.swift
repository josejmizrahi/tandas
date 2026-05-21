import SwiftUI
import RuulCore
import RuulUI

/// Universal Resource Detail — **Identity layer**.
///
/// Answers the user's first question: *¿Qué es esto?*
///
/// Composes the existing identity ribbon (icon + title + subtitle
/// segments) with the state hero (headline + supporting facts + inline
/// primary action). This is a pure composition wrapper — no new
/// rendering — introduced in PR 2 of the layered-detail rebuild so the
/// rest of the codebase can refer to the layer by name as PRs 3-7 fill
/// in Participation / Coordination / Activity / Actions around it.
///
/// Per the doctrine in `Plans/Active/Fase1ComponentMap.md` §"Universal
/// Resource Detail — layered architecture", the Identity layer is the
/// only layer that's always visible — the rest hide when empty.
@MainActor
struct IdentityLayerView: View {
    let identity: IdentityRibbon
    let state: StateHeadline
    let onPrimaryTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            IdentityRibbonView(ribbon: identity)
            StateHeroView(
                headline: state,
                tint: identity.tint,
                onPrimaryTap: onPrimaryTap
            )
        }
    }
}
