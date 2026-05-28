import SwiftUI
import RuulCore

/// V2-G5 — Reusable "Actuar en nombre de…" section for action sheets
/// that hit RPCs accepting `p_mandate_id`. Only renders when the
/// caller has at least one active mandate for the given scope; an
/// empty list collapses the section so sheets stay tight when there
/// are no representations active.
///
/// Caller owns the selection state — the section is purely
/// presentation. `selection == nil` means "actuando en mi nombre".
struct MandateBehalfPickerSection: View {
    @Binding var selection: UUID?
    let availableMandates: [GroupMandate]

    var body: some View {
        if availableMandates.isEmpty {
            EmptyView()
        } else {
            Section {
                Picker(selection: $selection) {
                    Text(L10n.Mandates.onBehalfSelf).tag(UUID?.none)
                    ForEach(availableMandates) { mandate in
                        rowLabel(for: mandate).tag(UUID?.some(mandate.id))
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(L10n.Mandates.onBehalfSection)
            } footer: {
                Text(L10n.Mandates.onBehalfFootnote)
            }
        }
    }

    @ViewBuilder
    private func rowLabel(for mandate: GroupMandate) -> some View {
        let principal = principalDescription(for: mandate)
        let title = String(format: String(localized: L10n.Mandates.onBehalfMandateRow),
                           principal,
                           String(localized: mandate.type.label))
        HStack(spacing: 8) {
            Image(systemName: mandate.type.systemImageName)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                if let endsAt = mandate.endsAt {
                    Text(endsAt, format: .dateTime.day().month().year())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(L10n.Mandates.openEndedHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// "Por el grupo" / "Por un comité" / etc. — falls back to the
    /// principal type label when we don't have a richer name on hand.
    private func principalDescription(for mandate: GroupMandate) -> String {
        String(localized: mandate.principalType.label)
    }
}
