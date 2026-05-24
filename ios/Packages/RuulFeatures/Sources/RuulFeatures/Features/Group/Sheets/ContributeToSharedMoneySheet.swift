import SwiftUI
import RuulCore
import RuulUI

/// SharedMoney Phase 3 (brick 4): group-scoped contribution sheet,
/// invoked from `SharedMoneyCard`'s "Aportar" CTA in `GroupSpaceView`.
///
/// Unlike the legacy `ContributeToFundSheet`, the caller supplies only
/// `groupId` — the wrapper RPC resolves the canonical shared pool
/// internally (mig 00363). iOS never needs to know the pool's `fundId`
/// for the default "money lives in the group" flow.
///
/// Submit path:
///   `FundRepository.contributeToSharedMoney(groupId, amountCents,
///   currency, note, sourceResourceId, clientId)` →
///   `contribute_to_shared_money` RPC → `fund_contribute` →
///   `record_ledger_entry` (type='contribution') →
///   `group_money_summary_view` reflects the new balance on next read.
///
/// Legacy `ContributeToFundSheet` stays alive untouched per
/// `doctrine_fund_per_event_deprecation.md` — it serves the Protected
/// Funds advanced surface, a different mental model.
public struct ContributeToSharedMoneySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let groupId: UUID
    public let currency: String
    /// When set, the entry is attributed to a specific resource
    /// (event/asset/space) via mig 00360 `p_source_resource_id`. Phase 4
    /// passes this from the resource Money Block; Phase 3 leaves it nil.
    public let sourceResource: (id: UUID, name: String)?
    /// Called after a successful contribute so the caller can refresh
    /// the shared pool summary.
    public let onDidContribute: () -> Void

    @State private var amountText: String = ""
    @State private var note: String = ""
    /// SharedMoney Phase 4.5 (mig 00364): when on, stamps the entry as
    /// in-kind contribution (terreno, equipo, donated valuable) — the
    /// amount is the agreed valuation, not cash that hit the pool.
    /// Distinguishes capital contributions from cash deposits for the
    /// per-member breakdown surface. Hidden when no sourceResource is
    /// attached (cash-only pool flow doesn't need the distinction).
    @State private var isInKind: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    /// Stable idempotency key (mig 00351). Generated once per sheet
    /// open; re-taps after a network error reuse it so the server
    /// returns the existing ledger row instead of duplicating.
    @State private var clientId: UUID = UUID()

    public init(
        groupId: UUID,
        currency: String,
        sourceResource: (id: UUID, name: String)? = nil,
        onDidContribute: @escaping () -> Void
    ) {
        self.groupId = groupId
        self.currency = currency
        self.sourceResource = sourceResource
        self.onDidContribute = onDidContribute
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let sourceResource {
                        Label("Para \(sourceResource.name)", systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                } footer: {
                    Text(sourceResource != nil
                         ? "Tu aportación queda registrada como parte de esto."
                         : "Tu aportación entra al dinero compartido del grupo.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Section("Monto (\(currency))") {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                }

                // Only meaningful when aporting against a specific
                // resource (warehouse, vehicle, viaje) — cash to the
                // pool itself doesn't need the cash-vs-in-kind
                // distinction. Hidden when sourceResource is nil.
                if sourceResource != nil {
                    Section {
                        Toggle("Aporte en especie", isOn: $isInKind)
                    } footer: {
                        Text(isInKind
                             ? "El monto representa el valor estimado del aporte no monetario (terreno, equipo, etc.)."
                             : "El monto entró en efectivo al recurso. Activa si aportaste algo con valor (no dinero).")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }

                Section("Nota (opcional)") {
                    TextField("ej: Aporte de marzo", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .ruulSheetToolbar("Aportar al dinero compartido")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Aportando…" : "Aportar") {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || amountCents == nil)
                }
            }
        }
    }

    private var amountCents: Int64? {
        let trimmed = amountText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let pesos = Double(trimmed), pesos > 0 else {
            return nil
        }
        return Int64((pesos * 100).rounded())
    }

    @MainActor
    private func submit() async {
        guard let cents = amountCents else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await app.fundRepo.contributeToSharedMoney(
                groupId: groupId,
                amountCents: cents,
                currency: currency,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                sourceResourceId: sourceResource?.id,
                clientId: clientId,
                inKind: isInKind
            )
            onDidContribute()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
