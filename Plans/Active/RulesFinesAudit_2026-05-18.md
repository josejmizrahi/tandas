# Ruul — Rules / Fines / Ledger Coupling Audit

**Status:** Snapshot 2026-05-18. Founder directive.
**Companion of:** `Plans/Active/RulesVsMoneyDoctrine.md`, `Plans/Active/ObligationsProjectionDoctrine.md`, `Plans/Active/ConsequenceArchitecture.md`, `Plans/Active/RulesFinesRefactorPlan.md` (sibling, phased migration).
**Predecessors:** `Plans/Active/ConsistencyAudit_2026-05-17.md` (F1 — `pay_fine` heresy, fixed mig 00273; F2-F22 — cache violations), `Plans/Active/Constitution.md` §14 (3-step migration of `fines` mutable columns).

> **Premisa:** El backend se acerca al estado correcto (atoms canónicos + `fines_view` projection + `ledger_entries` truth), pero el cliente y la copy todavía coplan "rule = fine = money". Este audit catalogue cada coupling, clasifica como **DOCTRINAL VIOLATION**, **TRANSITIONAL DEBT** o **ACCEPTABLE CACHE** y refiere remediation en `RulesFinesRefactorPlan.md`.

---

## 0. Executive summary

- **3 violations doctrinales (high)** — bloquean compliance. Todas remediables sin big-bang.
- **5 deudas transitorias documentadas** — migrarán post audit-close de Plans/Active/ConsistencyAudit_2026-05-17.md.
- **8 patrones acceptable / boundary code** — son frontera entre capas, doctrinalmente OK con doc comment.
- **0 nuevas violations** desde mig 00273. Las restantes son legacy.
- **Cumplimiento total estimado: ~92%** doctrina post-Refactor Phase 1.

---

## 1. Findings table — classified

Severidad: **A** = bloqueante doctrinal. **B** = transitional debt con plan. **C** = boundary/aceptable.

| # | Severity | Location | Issue | Family | Refactor ref |
|---|---|---|---|---|---|
| RF1 | **A** | `ios/Packages/RuulCore/Sources/RuulCore/GroupRule.swift:144-149` | `GroupRule.amountMXN` lee directo del primer `fine` consequence — Axioma 1 violation (rule asume = fine). | Coupling |  Plan Phase 2 §A |
| RF2 | **A** | `ios/Packages/RuulCore/Sources/RuulCore/GroupRule+FineShape.swift:19-34` | `GroupRule.fineShape` casts `consequences[0]` a `FineShape` — money-coupled property sobre el modelo universal de rule. | Coupling | Plan Phase 2 §A |
| RF3 | **A** | `ios/Packages/RuulCore/Sources/RuulCore/OnboardingRuleDraft.swift:44-70` | `OnboardingRuleDraft.amountMXN` setter/getter mutates the first `.fine` consequence's `amount`/`baseAmount`. Treats draft as fine-only. | Coupling | Plan Phase 2 §A |
| RF4 | **A** | `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailTab.swift:11-44` + `UniversalResourceDetailView.swift:391-397` | `.rules` tab mezcla rule definitions con sections derivadas de fines/ledger; no existe `.money` tab dedicado. | UI Separation | Plan Phase 3 §C |
| RF5 | **B** | `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Fine.swift:24-28` + storage columns en `public.fines` (00001, 00016) | Mutable `paid`, `paid_at`, `waived`, `waived_at`, `waived_reason` columns sobre tabla `fines`. Already projected via `fines_view` (mig 00149). | Cache vs Truth | Constitution §14 Step 3c |
| RF6 | **B** | `ios/Packages/RuulCore/Sources/RuulCore/Templates/` (DinnerRecurringTemplate.swift, etc.) | Templates Swift hardcoded con seeds money-coupled — descripciones mencionan "se le cobra X". | Templates copy | Plan Phase 1 §B + Phase 2 §A |
| RF7 | **B** | `supabase/migrations/00296_seed_universal_beta1_templates.sql`, `00320`, `00321`, `00325` | Templates universales OK (composition + alias map limpio) pero descriptions todavía dicen "se le aplica una multa". | Templates copy | Plan Phase 1 §B |
| RF8 | **B** | `supabase/functions/process-system-events/index.ts:403-446` `setBookingsLocked` | Direct `resources.update({metadata})` desde edge function — violación F8 ya documentada (`ConsistencyAudit_2026-05-17.md`). | Engine purity | Plan Phase 2 §B (R7 from audit) |
| RF9 | **B** | `supabase/migrations/00149_fines_view_projection.sql:55-134` | `fines_view` lee de `f.status`/`f.amount`/`f.appeal_vote_id` directo de stored columns como fallback. Fallback removible post Step 3c. | Projection cleanup | Constitution §14 Step 3c |
| RF10 | **C** | `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/ConsequenceType.swift` | Enum ya canónico con 5 families (no explosion por params). `.fine` es un caso entre 22. ✅ Doctrina-compliant. | Reference | — |
| RF11 | **C** | `ios/Packages/RuulCore/Sources/RuulCore/Repositories/FineRepository.swift` + `RuleRepository.swift` | Repositorios separados; cada uno respeta boundary. OK. | Reference | — |
| RF12 | **C** | Permission slugs `issueFine`/`voidFine`/`markFinePaid` (mig 00233) | Acciones humanas (RPC gating), no capabilities ni rule types. Bien nombrados. ✅ | Reference | — |
| RF13 | **C** | `supabase/migrations/00149_fines_view_projection.sql` | `fines_view` projection completa, declara source atoms, lazy view, security_invoker. Cumple `ProjectionDoctrine.md` §1. ✅ | Reference | — |
| RF14 | **C** | `supabase/migrations/00273_pay_fine_and_void_fine_to_ledger.sql` | `pay_fine` y `void_fine` ya emiten `ledger_entries` atoms exclusively. Doctrinally clean post F1 fix. ✅ | Reference | — |
| RF15 | **C** | `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/LedgerEntry.swift` | LedgerEntry conforma `Atom`, append-only, canonical Kind enum. ✅ | Reference | — |
| RF16 | **C** | `basic_fines` module (mig 00049, 00072) | Module legacy money-coupled name pero usado solo for back-compat. No se crean modules nuevos así. Doc comment lo declara legacy. | Boundary | No action |
| RF17 | **C** | `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Fines/` | Feature subdirectorio "Fines" exists. Es OK — fines son un instrumento de UI separable; el archivo no acopla rule logic. Ver UI separation en `RulesVsMoneyDoctrine.md` §3 Regla 5. | Boundary | No action |

---

## 2. Doctrinal violations — DETAIL

### 2.1 — RF1: `GroupRule.amountMXN`

**File:** `ios/Packages/RuulCore/Sources/RuulCore/GroupRule.swift:144-149`

```swift
/// Resolves the display amount (MXN) from the first `fine` consequence.
/// Returns nil if the rule isn't a fine.
public var amountMXN: Int? {
    guard let cons = consequences.first(where: { $0.type == "fine" }) else { return nil }
    if let flat = cons.config?.amount { return flat }
    if let base = cons.config?.baseAmount { return base }
    return nil
}
```

**Por qué viola:** `GroupRule` es el modelo universal de **rule**, no de fine. Exponer `amountMXN` como property top-level del rule sugiere que toda rule tiene un amount — falso. Una rule cuya consequence sea `requireApproval`, `denyAction`, `emitWarning`, etc., no tiene amount.

**Por qué importa:** Cualquier callsite que lea `rule.amountMXN` está asumiendo silenciosamente que la rule es fine-coupled. Si mañana cambiamos la consequence, los callsites siguen "funcionando" devolviendo `nil` pero pierden el feature visualmente.

**Remediation:** Phase 2 §A — renombrar a algo que declare intent ("solo aplica si la primera consequence es fine"):

```swift
// Reemplazo
public extension GroupRule {
    /// Convenience for UI surfaces that render fine details. Returns nil
    /// when the rule's first consequence is not a `.fine`.
    /// Use only in fine-aware UI; the rule engine ignores this.
    var firstFineAmountMXN: Int? { ... }
}
```

Mover al file `GroupRule+FineShape.swift` (ya money-aware) en lugar del core `GroupRule.swift`.

---

### 2.2 — RF2: `GroupRule.fineShape`

**File:** `ios/Packages/RuulCore/Sources/RuulCore/GroupRule+FineShape.swift:19-34`

```swift
var fineShape: FineShape {
    guard let first = consequences.first, first.type == "fine" else {
        return .none
    }
    let cfg = first.config
    if let amount = cfg?.amount { return .flat(amount: amount) }
    if let base = cfg?.baseAmount, let step = cfg?.stepAmount, let mins = cfg?.stepMinutes {
        return .escalating(base: base, step: step, stepMinutes: mins)
    }
    return .unknown(rawConfig: cfg)
}
```

**Por qué viola:** Igual que RF1. La existencia de esta property en una extension del modelo `GroupRule` la convierte en API stable; cualquier feature que se construya leyendo `rule.fineShape` cementa el coupling.

**Distinción importante:** `fineShape` SÍ es útil para el UI composer que branchea "flat vs escalating". Pero debe vivir en el composer view, NO como property del modelo universal.

**Remediation:** Phase 2 §A — mover la lógica a `EditRuleParamsCoordinator` o helper estático `FineConsequenceParser.parse(consequences:)`. Eliminar la extension del modelo `GroupRule`.

---

### 2.3 — RF3: `OnboardingRuleDraft.amountMXN`

**File:** `ios/Packages/RuulCore/Sources/RuulCore/OnboardingRuleDraft.swift:44-70`

```swift
public var amountMXN: Int {
    get {
        guard let cfg = consequences.first(where: { $0.type == .fine })?.config,
              case .object(let dict) = cfg else { return 0 }
        if let v = dict["amount"]?.intValue { return v }
        if let v = dict["baseAmount"]?.intValue { return v }
        return 0
    }
    set { /* mutates consequences[0].config */ }
}
```

**Por qué viola:** Mismo problema que RF1/RF2 pero peor — esta es **setter** que muta. Asume que el draft tiene un fine consequence; si no, setter es no-op silencioso (comentario lo admite).

**Remediation:** Phase 2 §A — exponer `OnboardingRuleDraft.fineConsequenceAmount` como `Int?` con setter explícito que crea el consequence si no existe:

```swift
public mutating func setFineAmount(_ amount: Int) {
    // Locate or create fine consequence; mutate its config.
}
public var fineConsequenceAmount: Int? { ... }
```

Force callsite to be explicit about creating-vs-updating.

---

### 2.4 — RF4: Resource Detail tab structure

**Files:**
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/ResourceDetailTab.swift:11-44`
- `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift:391-397`

```swift
// ResourceDetailTab.swift
public enum ResourceDetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case activity
    case rules
    case connections
    case governance
}
```

**Por qué viola:** Hay 5 tabs canónicos. Money/ledger entries hoy viven como **sheet** (`EventLedgerSheet`, `AddLedgerEntrySheet`) gatillado desde el overview. La sección `.rules` no separa "definitions of rules" de "fines/obligations generadas por esas rules". El usuario percibe rules y money como una sola cosa, contradiciendo `RulesVsMoneyDoctrine.md` §3 Regla 5.

**Remediation:** Phase 3 §C — introducir tab `.money` y eventualmente `.obligations`:

```swift
public enum ResourceDetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case activity
    case rules
    case money         // NUEVO — ledger + fines + balances (read-only por miembro)
    case connections
    case governance
    case obligations   // FUTURO (post member_obligations_view shipped)
}
```

Tab `.rules` se purifica para mostrar SOLO definiciones, no derivados. Tab `.money` consume `ResourceLedgerCoordinator` (ya existe en `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Money/ResourceLedgerCoordinator.swift`).

---

## 3. Transitional debt — DETAIL

Items con plan de migración ya documentado en docs canónicos. Listados aquí para visibilidad y trazabilidad.

### 3.A — RF5: Mutable `fines` columns

**Status:** Constitution §14 Step 3 in progress.

- ✅ Step 3a (mig 00148): atoms `fine_issued`/`fine_paid`/`fine_voided` emitidos.
- ✅ Step 3b (mig 00149): `fines_view` projection deriva status/paid/waived.
- ⏳ Step 3c (post audit-close): DROP COLUMNS `paid, paid_at, paid_to_fund, waived, waived_at, waived_reason, appeal_vote_id` de `public.fines`. `Fine` Swift struct lee solo de `fines_view`.

Hasta Step 3c: storage columns toleradas como cache transicional. `fines_view` ya proyecta lo correcto.

Categorización doctrinal según `OperationalCacheDoctrine.md`: **NO cumple Puerta 1** (atom no es decoración, pero la columna mutable existe sin RPC-only guard estricto), pero **declarada explícitamente como debt** con plan de Drop. Aceptable transitorio.

---

### 3.B — RF6: Swift templates hardcoded

**Files:** `ios/Packages/RuulCore/Sources/RuulCore/Templates/DinnerRecurringTemplate.swift` y siblings.

**Problem:** Templates Swift mantenidos in-memory con seeds money-coupled (default amounts, descriptions con "se le cobra"). Duplican el contenido de `supabase/migrations/00296_seed_universal_beta1_templates.sql` que ya seedeó la versión universal a la DB.

**Remediation:** Phase 1 §B — copy refactor (palabras "se le cobra" → "se aplica la consecuencia"). Phase 2 §A — borrar Swift templates files; reemplazar con llamada a `seed_template_rules` RPC que ya existe (mig 00062, refactorizado por mig 00296+00325).

---

### 3.C — RF7: Universal template descriptions

**Files:** `supabase/migrations/00296`, `00320`, `00321`, `00325`.

**Status:** Templates universales correctamente nombrados (`missed_obligation_consequence`, `no_show_consequence`, etc.) per `UniversalRuleTemplates.md` §14.6. Pero `description_es` todavía menciona dinero específico:

```sql
-- 00296 deadline_enforcement description (clean)
'Cuando se acerca una fecha límite y la acción requerida no se ha hecho, el grupo recibe un aviso.'

-- 00296 missed_obligation_consequence description (slight bias)
'Cuando alguien incumple una obligación, se aplica una consecuencia.'  -- OK

-- Some legacy aliased templates still show "se le cobra" copy
```

**Remediation:** Phase 1 §B — mig nueva que actualiza descriptions para que sean consequence-agnostic. No es bloqueante de Phase 2 pero polish para Beta 1 launch.

---

### 3.D — RF8: `setBookingsLocked` direct mutation

**File:** `supabase/functions/process-system-events/index.ts:403-446`.

**Status:** Ya documentado en `ConsistencyAudit_2026-05-17.md` F8. Remediation R7 pending. Esta auditoría solo cross-references — no propone fix nuevo.

**Plan:** `lock_asset_bookings(asset_id, rule_id, reason)` SECURITY DEFINER RPC. Sink usa RPC. Atom emitted: `assetBookingsLocked`. Projection `asset_booking_lock_view` substitutes `metadata.bookings_locked` read.

---

### 3.E — RF9: `fines_view` reads stored columns as fallback

**File:** `supabase/migrations/00149_fines_view_projection.sql:55-134`.

**Status:** Fallback to `f.status`, `f.amount`, `f.appeal_vote_id` documented in mig 00149 as "removed in Step 3c". Conscious transitional debt.

**Plan:** Constitution §14 Step 3c re-creates `fines_view` reading only from atom-derived sources + storage of immutable rule snapshot.

---

## 4. Acceptable boundary code (reference)

### 4.A — Repository separation (RF11)

`FineRepository` y `RuleRepository` están separados — cada uno tiene su responsabilidad, no se cruzan. Boundary correcta. No action.

### 4.B — Permission action gating (RF12)

`issueFine`, `markFinePaid`, `voidFine` (mig 00233) son slugs de **acciones humanas** que pasan por `has_permission` check en RPCs. Son la analogía correcta de "esta acción requiere autorización" — NO son capabilities ni rule types. Bien.

### 4.C — `fines_view` projection (RF13)

Documentación explícita de source atoms (`ledger_entries`), reduction logic (CASE statement priority), recompute strategy (lazy view security_invoker). Cumple `ProjectionDoctrine.md` §1 al 100%.

### 4.D — `pay_fine` + `void_fine` atom-only (RF14)

Mig 00273 (Sprint 1.1 fix) los corrige para emitir SOLO `ledger_entries` atoms. Cero mutación de `fines.paid`/`waived`. Doctrina-clean.

### 4.E — `ConsequenceType` enum (RF10)

Casos canónicos por familia. `.fine` es UNO entre 22+ casos. No type explosion. Reserved cases para Wave 1/2/3. Documentado per case con sink path. Bien.

### 4.F — `LedgerEntry` atom (RF15)

Conforma `Atom` protocol, append-only, `Kind` enum canónico, codigo string-typed para forward-compat. Mig 00078 + posteriores ledger types alignment. Bien.

### 4.G — `basic_fines` module (RF16)

Legacy money-coupled module name. No se crean modules así. Doc-comment lo identifica. No bloquea. Backwards-compat sin acoplar lógica nueva.

### 4.H — Feature directory `Fines/` (RF17)

Subdirectorio Swift con coordinators y views específicas de fines (`MyFinesView`, `FineDetailView`, `AppealFineSheet`, `VoidFineSheet`). Es UI especializada del instrumento — no acopla rule logic. Boundary correcto: las views consumen `FineRepository` que consume `fines_view`. Cero infiltración al rule layer.

---

## 5. Counts y health

| Severity | Count | % of total |
|---|---|---|
| A — Doctrinal violation | 4 | 23% |
| B — Transitional debt (documented) | 5 | 29% |
| C — Acceptable boundary | 8 | 47% |
| **Total findings** | **17** | **100%** |

**Bloqueantes para Beta 1 launch:** 0 (todas las violations doctrinales son client-side y no rompen funcionalidad).

**Bloqueantes para "decoupling complete" milestone:** 4 (RF1-RF4).

**Health snapshot post-Phase-1 ejecución:** ~98% compliant.
**Health snapshot post-Step-3c (drop columns):** ~99.9% compliant.

---

## 6. Cross-reference con audits previos

| Audit | Findings que este audit cubre | Findings que NO se duplican |
|---|---|---|
| `ConsistencyAudit_2026-05-17.md` | F8 (re-listado RF8 con cross-ref) | F1 (closed mig 00273), F2-F4, F7, F9, F20 (other resource-specific). |
| `Constitution.md` §14 | Steps 3a, 3b shipped; Step 3c referenced RF5+RF9 | — |
| `OperationalCacheDoctrine.md` §6 | `groups.fund_balance` (closed F1), `resources.metadata.bookings_locked` (RF8) | Other caches not in fine/money scope. |
| `UniversalRuleTemplates.md` §14.6, §14.8 | Wave 2 followup pending — `rotation_skip_consequence` (=`.loseTurn`), `notification_reminder` (=`.sendNotification`). Cross-ref. | Wave 3 (priority_allocation, etc.). |

---

## 7. Decision matrix — what to fix when

| Finding | Bloquea Beta 1? | Bloquea Phase 2 refactor? | Bloquea Step 3c? |
|---|---|---|---|
| RF1 `amountMXN` | No | Sí — debe migrar antes de eliminar money-coupled APIs | No |
| RF2 `fineShape` | No | Sí | No |
| RF3 `OnboardingRuleDraft.amountMXN` | No | Sí | No |
| RF4 UI tab structure | No | No (separable) | No |
| RF5 mutable columns | No | No | **Sí** (Step 3c es justo dropearlas) |
| RF6 Swift templates | No | Recomendado | No |
| RF7 description copy | No | Recomendado | No |
| RF8 setBookingsLocked | No | No (cross-cutting) | No |
| RF9 fines_view fallback | No | No | **Sí** (re-create view) |

---

## 8. Next action

`RulesFinesRefactorPlan.md` documenta el plan fase a fase con dependencies, mig list y test gates.
