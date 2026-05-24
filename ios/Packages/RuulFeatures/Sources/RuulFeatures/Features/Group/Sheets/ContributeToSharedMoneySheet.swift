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
    /// SharedMoney P1 (asset valuation ↔ contribution link): when the
    /// in-kind toggle turns on AND `sourceResource` is an asset with
    /// recorded valuation history, we fetch the latest row and pre-fill
    /// `amountText`. Avoids the warehouse-case double-entry where the
    /// user has to type the same number in `RecordValuationSheet` and
    /// again here. nil when no valuation exists / fetch hasn't run yet.
    @State private var prefilledValuation: AssetValuation?
    /// Tracks whether `amountText` matches the auto-prefilled value so
    /// we know not to overwrite it once the user starts typing manually.
    @State private var amountIsAutoPrefilled: Bool = false
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

                Section {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .onChange(of: amountText) { _, _ in
                            // User edited → stop tracking auto-prefill
                            // so we don't overwrite their input later.
                            amountIsAutoPrefilled = false
                        }
                } header: {
                    Text("Monto (\(currency))")
                } footer: {
                    // SharedMoney P1: when the in-kind amount was
                    // populated from the asset's latest valuation,
                    // surface the provenance so the user understands
                    // why a number appeared automatically.
                    if amountIsAutoPrefilled, prefilledValuation != nil {
                        Text("Tomado de la valuación actual del activo.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }

                // Only meaningful when aporting against a specific
                // resource (warehouse, vehicle, viaje) — cash to the
                // pool itself doesn't need the cash-vs-in-kind
                // distinction. Hidden when sourceResource is nil.
                if sourceResource != nil {
                    Section {
                        Toggle("Aporte en especie", isOn: $isInKind)
                            .onChange(of: isInKind) { _, newValue in
                                Task { await applyValuationPrefillIfNeeded(turnedOn: newValue) }
                            }
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
            // SharedMoney P1: kick off a single best-effort valuation
            // fetch when the sheet opens so the toggle's prefill is
            // instant on first tap. The asset might not have a
            // valuation history — in that case the lookup just
            // returns nil and the toggle works as before.
            .task { await preloadValuationIfApplicable() }
        }
    }

    /// SharedMoney P1: when the in-kind toggle flips on, populate the
    /// amount field from the asset's latest valuation if available.
    /// Only overwrites the amount when the user hasn't typed anything
    /// (empty) — once they edit, their value wins. Toggling off does
    /// NOT clear what's there; the user may have edited the prefill
    /// or typed cash equivalently.
    @MainActor
    private func applyValuationPrefillIfNeeded(turnedOn: Bool) async {
        guard turnedOn else { return }
        if prefilledValuation == nil {
            await preloadValuationIfApplicable()
        }
        guard let valuation = prefilledValuation else { return }
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || amountIsAutoPrefilled {
            let pesos = Decimal(valuation.valueCents) / 100
            amountText = formatPlainDecimal(pesos)
            amountIsAutoPrefilled = true
        }
    }

    /// Best-effort one-shot fetch of the asset's latest valuation
    /// (sourceResource may not be an asset — non-asset rows simply
    /// return nil and the prefill never fires).
    @MainActor
    private func preloadValuationIfApplicable() async {
        guard let source = sourceResource else { return }
        if prefilledValuation != nil { return }
        let resourceId = source.id
        let repo = app.assetLifecycleRepo
        prefilledValuation = try? await repo.latestValuation(asset: resourceId)
    }

    /// Format a Decimal as "1234.56" without thousands separators so
    /// the text field can re-parse it via the same logic as user input.
    private func formatPlainDecimal(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.decimalSeparator = "."
        return f.string(from: value as NSDecimalNumber) ?? "\(value)"
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
            // SharedMoney P1 brick 3: when the user records an in-kind
            // contribution against an asset, also append a valuation
            // atom so the asset's recorded valuation stays in sync.
            // Best-effort — failures don't roll back the contribution.
            // Skipped when amount matches the prefill (no semantic
            // change) or when the resource isn't an asset (the call
            // will fail RLS / not-found, which we silently swallow).
            await syncValuationIfApplicable(cents: cents)

            onDidContribute()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// SharedMoney P1 brick 3 — write-back path. When an in-kind
    /// contribution targets an asset whose valuation differs from the
    /// amount recorded, append a fresh valuation atom so the asset's
    /// next reader sees the canonical number.
    @MainActor
    private func syncValuationIfApplicable(cents: Int64) async {
        guard isInKind, let source = sourceResource else { return }
        // Skip the redundant write when the amount already matches
        // the prefilled valuation — no semantic change to record.
        if let prior = prefilledValuation, prior.valueCents == cents {
            return
        }
        _ = try? await app.assetLifecycleRepo.recordValuation(
            asset: source.id,
            valueCents: cents,
            currency: currency,
            source: "contribution",
            notes: "Sincronizado desde aportación en especie"
        )
    }
}
