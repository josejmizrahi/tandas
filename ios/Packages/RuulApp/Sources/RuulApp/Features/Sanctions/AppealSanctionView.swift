import SwiftUI
import RuulCore

/// Placeholder surface for the future "apelar a voto" flow (Primitiva
/// 14 → 16 escalation). Backend RPC for `escalate_sanction_to_vote`
/// exists but the iOS-facing wiring + voting UI ships with C1
/// Decisions/Voting (see `Plans/Active/UIBottomUpPlan.md` §3 C1).
/// For now this view tells the user where the affordance is going.
struct AppealSanctionView: View {
    let sanction: GroupSanction

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ContentUnavailableView {
            Label(L10n.AppealSanction.placeholderTitle, systemImage: "scale.3d")
        } description: {
            Text(L10n.AppealSanction.placeholderBody)
        }
        .navigationTitle(L10n.AppealSanction.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: L10n.AppealSanction.close)) {
                    dismiss()
                }
            }
        }
    }
}
