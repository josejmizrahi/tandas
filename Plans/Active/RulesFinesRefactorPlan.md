# Ruul — Rules / Fines / Ledger Refactor Plan

**Status:** Plan 2026-05-18. Founder directive.
**Companion of:** `Plans/Active/RulesVsMoneyDoctrine.md`, `Plans/Active/ObligationsProjectionDoctrine.md`, `Plans/Active/ConsequenceArchitecture.md`, `Plans/Active/RulesFinesAudit_2026-05-18.md` (sibling audit con findings RF1-RF17), `Plans/Active/ConsistencyAudit_2026-05-17.md` (audit-close freeze que precede a Phase 2), `Plans/Active/Constitution.md` §14 (Step 3c que cierra cleanup de columnas).

> **Principios de ejecución:**
> - **No big bang.** El refactor preserva ontología (6 resource types), atoms (`ledger_entries`, `system_events`), projections (`fines_view`), capabilities, rule engine determinístico.
> - **No ontology rewrite.** Tablas se mantienen; storage que sobra se dropea solo después de readers migrados.
> - **Backwards-compat first.** En cada fase, antes de borrar algo se valida que cero callsites lo lean.
> - **Atom-driven.** Cada cambio que afecte estado emite atom; nunca reverse.
> - **Frozen during ConsistencyAudit close.** Phase 2 arranca después de audit-close (cerrar Sprints 1-4 del 2026-05-17 audit).

---

## 0. Visión de fases

```
┌─────────────────────────────────────────────────────────┐
│ Phase 0 — Pre-flight (NOW, in-flight in docs only)      │
│   Doctrine docs canónicos + audit publicado             │
│   Effort: 0 days (este commit)                          │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────┐
│ Phase 1 — Copy refactor (1-2 days)                      │
│   Templates description money-agnostic                   │
│   Doc comments deprecation en money-coupled APIs        │
│   No breaking change                                     │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼ blocked by ConsistencyAudit close
┌─────────────────────────────────────────────────────────┐
│ Phase 2 — API decoupling (3-5 days)                     │
│   Renombrar amountMXN / fineShape                        │
│   Mover lógica a fine-aware coordinators                 │
│   Borrar Swift templates files (use mig 00296 seeds)    │
│   F8 fix (lock_asset_bookings RPC)                      │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼ blocked by Phase 2 callsites green
┌─────────────────────────────────────────────────────────┐
│ Phase 3 — UI separation (2-3 days)                      │
│   Tab .money en ResourceDetailTab                       │
│   Tab .rules purificado (cero balance display)          │
│   Copy reorientado per RulesVsMoneyDoctrine §3 Regla 5  │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼ blocked by Phase 3 stable
┌─────────────────────────────────────────────────────────┐
│ Phase 4 — Constitution §14 Step 3c (1-2 days)           │
│   DROP COLUMNS fines.paid/waived/...                    │
│   Re-create fines_view sin fallback                     │
│   Fine struct lee solo de fines_view                    │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼ shippable independently
┌─────────────────────────────────────────────────────────┐
│ Phase 5 — Obligations projections (Wave 1-2, futuro)    │
│   outstanding_fines_view                                 │
│   member_obligations_view                               │
│   Tab .obligations en ResourceDetailTab                  │
│   Capacities for Wave 2 templates                        │
└─────────────────────────────────────────────────────────┘
```

---

## Phase 0 — Pre-flight (este commit)

**Deliverables:**

- ✅ `Plans/Active/RulesVsMoneyDoctrine.md`
- ✅ `Plans/Active/ObligationsProjectionDoctrine.md`
- ✅ `Plans/Active/ConsequenceArchitecture.md`
- ✅ `Plans/Active/RulesFinesAudit_2026-05-18.md`
- ✅ `Plans/Active/RulesFinesRefactorPlan.md` (this doc)

**Side-effects:** none. Pure documentation.

**Acceptance:** docs reviewed and merged on branch `claude/separate-rules-fines-*`.

---

## Phase 1 — Copy refactor (1-2 days)

**Goal:** Eliminar copy money-biased sin tocar APIs. Pure user-facing strings + doc-comment.

### 1.1 — Template descriptions

Migration: `00327_template_descriptions_consequence_agnostic.sql` (next free number after 00326).

```sql
UPDATE public.rule_templates SET description_es = $$
  Cuando alguien incumple una obligación (ej. no asistir, no confirmar a tiempo,
  no cumplir un compromiso), se ejecuta la consecuencia configurada por el grupo.
$$
WHERE id = 'missed_obligation_consequence';

UPDATE public.rule_templates SET description_es = $$
  Cuando alguien no asiste a un evento al que se comprometió, se ejecuta la
  consecuencia configurada por el grupo (multa, advertencia, pérdida de prioridad).
$$
WHERE id = 'no_show_consequence';

-- Repetir para late_cancellation_consequence, no_rsvp_consequence, cancellation_consequence,
-- deadline_consequence, booking_cancellation_consequence, late_return_consequence.
```

Verificación: `npx tsx scripts/codegen/dump-templates.ts` muestra strings limpios.

### 1.2 — Swift doc-comment deprecation

Agregar deprecation comments **sin** borrar APIs (la deprecation real es Phase 2):

```swift
// ios/Packages/RuulCore/Sources/RuulCore/GroupRule.swift:144

/// **Deprecated since 2026-05-18.** Use `GroupRule+FineShape.fineFirstAmountMXN`
/// helper or `EditRuleParamsCoordinator.amountForFineConsequence(of:)`.
/// This property assumes the rule's first consequence is `.fine`, violating
/// `RulesVsMoneyDoctrine.md` Axioma 1 ("Rule ≠ Fine"). Phase 2 of
/// `RulesFinesRefactorPlan.md` removes it.
public var amountMXN: Int? { /* same */ }
```

Mismo doc-comment en:
- `GroupRule+FineShape.swift::fineShape`
- `OnboardingRuleDraft.swift::amountMXN`

### 1.3 — `Fine` struct header comment

```swift
// ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Fine.swift

/// **Storage columns `paid`, `paidAt`, `waived`, `waivedAt`, `waivedReason`
/// are transitional debt** per Constitution §14 Step 3c — to be dropped post
/// audit-close. Readers MUST consume `public.fines_view` projection, not raw
/// storage, since the view derives state from `ledger_entries` atoms.
/// See `RulesVsMoneyDoctrine.md` Axioma 2 and `OperationalCacheDoctrine.md`
/// §6 entry.
public struct Fine: Identifiable, Sendable, Hashable, Codable { /* same */ }
```

### 1.4 — Templates Swift files

Same approach — header comment declarando que el file se borra Phase 2:

```swift
// ios/Packages/RuulCore/Sources/RuulCore/Templates/DinnerRecurringTemplate.swift

/// **Deprecated since 2026-05-18.** This Swift-hardcoded template duplicates
/// the universal templates seeded in `supabase/migrations/00296`/`00320`/`00321`/
/// `00325`. Phase 2 of `RulesFinesRefactorPlan.md` deletes this file; callers
/// migrate to `seed_template_rules('recurring_dinner')` RPC.
```

### 1.5 — Effort + acceptance

- **Effort:** 0.5 day SQL mig + 0.5 day Swift doc comments.
- **Acceptance:**
  - Mig applied via `mcp__supabase__apply_migration`.
  - `xcodebuild test` passes (no API changes).
  - Spanish copy reviewed by founder.
- **Risk:** none. Pure copy.

---

## Phase 2 — API decoupling (3-5 days)

**Goal:** Eliminar las 3 violations doctrinales del modelo `GroupRule` (RF1, RF2, RF3) y consolidar templates en seeds DB.

**Pre-requisite:** ConsistencyAudit close (Sprints 1-4 done).

### 2.A — Swift API surgery

#### 2.A.1 — `GroupRule.amountMXN` → eliminado del modelo

1. Crear `RuulCore/PlatformModels/Helpers/FineConsequenceParser.swift`:

```swift
public enum FineConsequenceParser {
    /// Returns the first `fine` consequence's amount (flat or base).
    /// Nil if no fine consequence exists.
    public static func firstAmountMXN(in consequences: [GroupRule.ConsequenceEnvelope]) -> Int? {
        guard let cons = consequences.first(where: { $0.type == "fine" }) else { return nil }
        return cons.config?.amount ?? cons.config?.baseAmount
    }
}
```

2. Delete `GroupRule.amountMXN` property.

3. Migrate callsites — grep:

```bash
grep -rn "\.amountMXN" ios/Packages/RuulFeatures/Sources/
# Expected: 5-10 callsites. Each replaces with FineConsequenceParser.firstAmountMXN(in: rule.consequences).
```

#### 2.A.2 — `GroupRule+FineShape` → mueve a coordinator

1. Mover el archivo a `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Rules/Internal/FineShape.swift`.
2. Convertir `var fineShape: FineShape` (extension on GroupRule) en `static func fineShape(of consequences:) -> FineShape`.
3. Migrate callsites (mismo patrón).

#### 2.A.3 — `OnboardingRuleDraft.amountMXN` → setter explícito

```swift
// Replacement
public mutating func setFineConsequenceAmount(_ amount: Int) {
    if let idx = consequences.firstIndex(where: { $0.type == .fine }) {
        // Mutate existing fine consequence
    } else {
        // Create one
        consequences.append(.init(type: .fine, config: .object(["amount": .int(amount)])))
    }
}

public var fineConsequenceAmount: Int? { /* getter only */ }
```

Setter ya no es no-op silencioso — crea si falta.

### 2.B — Templates seed DB-only

1. Borrar `ios/Packages/RuulCore/Sources/RuulCore/Templates/DinnerRecurringTemplate.swift` y siblings (después de verificar grep que no se llama directo).
2. Onboarding flow ya llama `seed_template_rules` RPC; verificar que el RPC seeds universal templates correctly post mig 00325.
3. Remove `TemplateRegistry.swift` references al Swift hardcoded set.

### 2.C — F8 fix — `lock_asset_bookings` RPC

Migration: `00328_lock_asset_bookings_rpc_and_view.sql`.

```sql
-- Atom-emitting RPC
CREATE OR REPLACE FUNCTION public.lock_asset_bookings(
    p_asset_id uuid, p_rule_id uuid, p_reason text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_group_id uuid;
BEGIN
  SELECT group_id INTO v_group_id FROM resources WHERE id = p_asset_id;
  IF v_group_id IS NULL THEN RAISE EXCEPTION 'asset not found'; END IF;

  -- Idempotency: dedupe on (asset_id, rule_id, last open atom)
  IF EXISTS (
    SELECT 1 FROM system_events
     WHERE event_type = 'assetBookingsLocked'
       AND reference_id = p_asset_id
       AND (metadata->>'rule_id')::uuid = p_rule_id
       AND NOT EXISTS (
         SELECT 1 FROM system_events s2
          WHERE s2.event_type = 'assetBookingsUnlocked'
            AND s2.reference_id = p_asset_id
            AND s2.created_at > system_events.created_at
       )
  ) THEN RETURN; END IF;

  PERFORM record_system_event(
    v_group_id, 'assetBookingsLocked', p_asset_id, NULL,
    jsonb_build_object('rule_id', p_rule_id, 'reason', p_reason)
  );
END;
$$;

-- Projection
CREATE VIEW public.asset_booking_lock_view WITH (security_invoker=on) AS
SELECT r.id AS asset_id,
       EXISTS (
         SELECT 1 FROM system_events lk
          WHERE lk.event_type = 'assetBookingsLocked'
            AND lk.reference_id = r.id
            AND NOT EXISTS (
              SELECT 1 FROM system_events un
               WHERE un.event_type = 'assetBookingsUnlocked'
                 AND un.reference_id = r.id
                 AND un.created_at > lk.created_at
            )
       ) AS bookings_locked
FROM public.resources r
WHERE r.resource_type = 'asset';
```

Update `supabase/functions/process-system-events/index.ts`:
- Reemplaza `setBookingsLocked` direct write con `await supabase.rpc('lock_asset_bookings', {...})`.

Update Swift `ResourceCapability` reader: leer `asset_booking_lock_view` en lugar de `resources.metadata.bookings_locked`.

Add `OperationalCacheDoctrine.md` §5 entry para `assetBookingsLocked`/`assetBookingsUnlocked` atoms. Close F8 in `ConsistencyAudit_2026-05-17.md`.

### 2.D — Effort + acceptance

- **Effort:** 3 days Swift surgery + 1 day SQL + 1 day tests/QA.
- **Acceptance:**
  - `grep -r "\.amountMXN" ios/` → 0 matches.
  - `grep -r "\.fineShape" ios/` → 0 matches outside `Internal/FineShape.swift`.
  - `xcodebuild test` green.
  - `test_engine_does_not_mutate_state_tables` POST-R5+R7 green.
  - `test_no_direct_resources_metadata_update_in_edge_fn` green.
- **Risk:** medium. Refactor de extensiones used across views — careful grep + atomic PR.

---

## Phase 3 — UI separation (2-3 days)

**Goal:** Tab `.money` separado, tab `.rules` purificado.

### 3.A — Add `.money` tab

1. Update `ResourceDetailTab.swift`:

```swift
public enum ResourceDetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case activity
    case rules
    case money         // NUEVO
    case connections
    case governance
}

public var label: String {
    switch self {
    case .money: return "Dinero"
    // ...
    }
}

public var symbol: String {
    switch self {
    case .money: return "creditcard"
    // ...
    }
}
```

2. Update `UniversalResourceDetailView.swift::tabContent` switch:

```swift
case .money: moneyContent
```

3. Add `moneyContent`:

```swift
@ViewBuilder private var moneyContent: some View {
    ResourceMoneyTabView(resource: context.resource)
        .environment(resourceLedgerCoordinator)
}
```

`ResourceMoneyTabView` (nuevo) consume:
- `ResourceLedgerCoordinator` (existe — `Money/ResourceLedgerCoordinator.swift`).
- `FineRepository.list(resourceId:)` filtrado por status.
- Member balance summary.

### 3.B — Purify `.rules` tab

Remove any sections from `CapabilitySectionCatalog` that render fines/balances on the `.rules` tab. Move them to `.money`.

Grep `tabId: "rules"` sections (`RulesSectionView.swift:15`):
- Verify section solo muestra rule definitions, no derivados.

### 3.C — Copy refresh

En `EmptyTab` messages:
- `.rules` → "Sin reglas configuradas. Las reglas del grupo aplican aquí por defecto."
- `.money` → "Aún no hay movimientos. Cuando alguien aporte, gaste, o pague, lo verás aquí."

### 3.D — Effort + acceptance

- **Effort:** 1 day tab structure + 1 day MoneyTab view + 0.5 day QA.
- **Acceptance:**
  - Visual review en simulador iOS 26 — tab "Dinero" muestra ledger + fines, tab "Reglas" muestra solo rule cards.
  - Snapshot tests updated.
  - `test_rules_tab_contains_no_money_section_id` (asserts CapabilitySectionCatalog rule-tabbed sections don't include `money`/`fines`/`balance` capabilities).
- **Risk:** low. UI-only refactor.

---

## Phase 4 — Constitution §14 Step 3c (1-2 days)

**Goal:** Drop mutable columns de `fines`, re-create `fines_view` sin fallback, Fine struct read-only desde view.

### 4.A — Migration

`00329_fines_drop_mutable_columns_step3c.sql`:

```sql
BEGIN;

-- Drop columns no longer needed (projection derives all)
ALTER TABLE public.fines
  DROP COLUMN paid,
  DROP COLUMN paid_at,
  DROP COLUMN paid_to_fund,
  DROP COLUMN waived,
  DROP COLUMN waived_at,
  DROP COLUMN waived_reason,
  DROP COLUMN appeal_vote_id;

-- Drop fallback `status` column eventually. Cautious: status field on auto_generated
-- fines used by grace-period logic. Verify finalize-fine-reviews cron migrated first.
ALTER TABLE public.fines DROP COLUMN status;

-- Re-create fines_view sin fallback
DROP VIEW public.fines_view;
CREATE VIEW public.fines_view WITH (security_invoker=on) AS
SELECT
    f.id, f.group_id, f.user_id, f.rule_id, f.event_id, f.resource_id,
    f.reason, f.amount, f.auto_generated, f.issued_by, f.details,
    f.created_at, f.updated_at, f.rule_snapshot,
    -- Status puramente derivado de atoms
    CASE
        WHEN EXISTS (SELECT 1 FROM ledger_entries le WHERE le.type='fine_voided' AND (le.metadata->>'fine_id')::uuid=f.id) THEN 'voided'
        WHEN EXISTS (SELECT 1 FROM ledger_entries le WHERE le.type='fine_paid'   AND (le.metadata->>'fine_id')::uuid=f.id) THEN 'paid'
        WHEN EXISTS (SELECT 1 FROM votes v WHERE v.vote_type='fine_appeal' AND v.reference_id=f.id AND v.status='open') THEN 'in_appeal'
        WHEN f.auto_generated AND f.event_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM fine_review_periods frp
             WHERE frp.event_id = f.event_id
               AND (frp.officialized_at IS NOT NULL OR frp.expires_at < now())
        ) THEN 'officialized'
        WHEN f.auto_generated THEN 'proposed'
        ELSE 'officialized'  -- Manual fines default to officialized (RPC creates them so)
    END AS status,
    EXISTS (SELECT 1 FROM ledger_entries le WHERE le.type='fine_paid' AND (le.metadata->>'fine_id')::uuid=f.id) AS paid,
    (SELECT le.occurred_at FROM ledger_entries le WHERE le.type='fine_paid' AND (le.metadata->>'fine_id')::uuid=f.id ORDER BY le.occurred_at DESC LIMIT 1) AS paid_at,
    EXISTS (SELECT 1 FROM ledger_entries le WHERE le.type='fine_voided' AND (le.metadata->>'fine_id')::uuid=f.id) AS waived,
    (SELECT le.occurred_at FROM ledger_entries le WHERE le.type='fine_voided' AND (le.metadata->>'fine_id')::uuid=f.id ORDER BY le.occurred_at DESC LIMIT 1) AS waived_at,
    (SELECT le.metadata->>'reason' FROM ledger_entries le WHERE le.type='fine_voided' AND (le.metadata->>'fine_id')::uuid=f.id ORDER BY le.occurred_at DESC LIMIT 1) AS waived_reason
FROM public.fines f;

COMMIT;
```

### 4.B — Swift adaptation

`Fine.swift` — decoder unchanged (view exposes same fields). But:

- Remove `init` callers that pass `paid: Bool` literal — those are tests; migrate to projecting from view.
- `FineRepository.list*` queries change `from('fines')` → `from('fines_view')`.

### 4.C — Tests gate

Before merge:
- `test_fines_view_recomputes_from_ledger_entries_only` — drop view, recreate, assert same set.
- `test_fine_struct_decodes_from_view_only` — integration test.
- `test_pay_fine_then_fines_view_shows_paid` — atom + projection round-trip.
- `test_void_fine_then_fines_view_shows_voided` — same.

### 4.D — Effort + acceptance

- **Effort:** 0.5 day mig + 0.5 day Swift tests + 1 day QA.
- **Acceptance:**
  - All readers compiled.
  - View recompute test green.
  - No regression in `MyFinesView`/`FineDetailView`.
- **Risk:** medium-high. Schema change. Rollback plan: migration is reversible if Swift readers haven't shipped yet (re-add columns + backfill from view). After 1 release cycle of cliente shipped, schema change is permanent.

---

## Phase 5 — Obligations projections (futuro, Wave 1-2)

**Goal:** Materialize `outstanding_fines_view`, `member_obligations_view`, tab `.obligations`. Out of scope para esta planeación inmediata — punteo para visibility.

### 5.A — Migrations (futuras)

```sql
-- outstanding_fines_view
CREATE VIEW public.outstanding_fines_view WITH (security_invoker=on) AS
SELECT fv.id, fv.group_id, fv.user_id, fv.resource_id, fv.amount, fv.created_at AS opened_at,
       fv.id AS source_atom_id  -- pointer to ledger fine_issued atom
FROM public.fines_view fv
WHERE fv.status IN ('proposed', 'officialized', 'in_appeal');

-- member_obligations_view (UNION ALL of 4 families)
-- ...
```

### 5.B — UI

Tab `.obligations` en `ResourceDetailTab`. Consume `member_obligations_view WHERE subject_member_id = auth.uid()`.

### 5.C — Effort

5-10 days. Sequenced after Wave 1 templates ship (priority_allocation, rotating_responsibility, etc.) que generen los nuevos coordination/access obligation atoms.

---

## 6. Dependencies graph

```
Phase 0 (this commit)
    │
    ├──> Phase 1 (anytime, no blockers)
    │
    │       (ConsistencyAudit close required here)
    │
    ▼
Phase 2 ───> Phase 3 ───> Phase 4 ───> Phase 5
   │             │           │
   │             │           └─ Schema change. Releases need to ship 4.B Swift code first.
   │             │
   │             └─ UI-only. Independent.
   │
   └─ API changes. Atomic PR.
```

---

## 7. Risk register

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Callsite grep misses an `amountMXN` reader | medium | medium | Phase 2 PR runs full codebase compile + tests; no extension import outside Core. |
| Phase 4 schema drop breaks pre-update clients | medium | high | Stage Phase 4 mig only after Phase 3 ships to TestFlight and observability shows zero reads from dropped columns. Or: rename column to `_legacy_paid` first, monitor 1 release, then drop. |
| Templates seed RPC missing for grupos antiguos | low | medium | Before Phase 2 §B, audit DB: any group whose `seed_template_rules('recurring_dinner')` never ran. Backfill. |
| `lock_asset_bookings` RPC breaks asset workflow | low | medium | Phase 2 §C is atomic mig + edge fn deploy. Rollback by reverting both. |
| UI tab adds complexity, Beta users confused | low | low | A/B internal first. Founder reviews. Spanish label "Dinero" tested. |

---

## 8. Sequencing notes

- **Phase 1 puede shippearse independiente** y ahora mismo si no se rompe el freeze. Es solo copy + doc-comments. Recommended ship inmediato post merge de este branch.
- **Phase 2 espera ConsistencyAudit close.** Sin eso, hay carry de finds (F8, F2, etc.) que confunden la refactor purity.
- **Phase 3 y Phase 2 pueden paralelizarse** si dos engineers trabajan branches separados — Phase 3 no toca APIs, Phase 2 no toca tabs UI.
- **Phase 4 espera Phase 3 deployed a TestFlight.** Schema drop solo después de validar zero legacy reads.
- **Phase 5 es Q3/Q4 backlog.** No bloquea Beta 1.

---

## 9. Definition of Done (cada fase)

| Item | Phase 1 | Phase 2 | Phase 3 | Phase 4 |
|---|---|---|---|---|
| Mig applied via MCP | ✓ (1 mig) | ✓ (1 mig F8) | — | ✓ (1 mig drop) |
| Swift compile clean | ✓ | ✓ | ✓ | ✓ |
| `xcodebuild test` green | ✓ | ✓ | ✓ | ✓ |
| Codegen sin diff | ✓ | ✓ | — | ✓ |
| Doc comments + audit refs updated | ✓ | ✓ | ✓ | ✓ |
| Founder UI review | — | — | ✓ | ✓ |
| ConsistencyAudit F8 closed | — | ✓ | — | — |
| Constitution §14 Step 3 closed | — | — | — | ✓ |
| Audit `RulesFinesAudit_2026-05-18.md` finding RFx marked closed | RF7 | RF1-3, RF6, RF8 | RF4 | RF5, RF9 |

---

## 10. Doctrina final

> **Sin big bang. Sin ontology rewrite. Sin breaking change para grupos en producción.**
>
> **Atoms permanecen. Projections permanecen. Capabilities permanecen.**
> **Solo se eliminan: APIs money-coupled del modelo universal, copy biased al dinero, storage que duplica la projection.**
>
> **El resultado: rules son universales. Fines son una consequence entre muchas. Ledger es la única verdad económica. Obligations son projection. UX humano.**

Post-Phase-4, el repo cumple los axiomas de `RulesVsMoneyDoctrine.md` al 99%+. Las únicas violaciones residuales son los `basic_fines` module name y permission slugs `issueFine` — boundary code aceptable que no atenta contra el principio.
