# Ruul — Rule Engine Doctrine

**Status:** Canónico desde 2026-05-17. Founder directive.
**Companion of:** `Plans/Active/Constitution.md` (Artículo 9 — rules gobiernan acciones, no son objetos), `Plans/Active/Governance.md` (Builder UX + grammar), `Plans/Active/AtomProjection.md`, `Plans/Active/ConsistencyAudit_2026-05-17.md` (findings F5, F8 — rule_evaluations dead-write + setBookingsLocked direct mutation).

> El **rule engine** es server-only, determinístico, idempotente, append-only en sus side effects, y completamente trazable. Una regla **decide** un veredicto y **emite atoms** o **arranca workflows**. **Nunca muta estado directamente.** Cada evaluación deja una fila en `rule_evaluations` con idempotency_key que previene doble-ejecución en retry.

> El error doctrinal en Ruul al 2026-05-17: la tabla `rule_evaluations` existe (mig 00181) con `UNIQUE idempotency_key` exactamente para este fin, pero `process-system-events/index.ts` **nunca INSERT en ella**. Cada `ConsequenceSink` reimplementa dedup ad-hoc (algunos no lo tienen). Además `setBookingsLocked` muta `resources.metadata` directamente desde edge function code — viola "rules no mutan".

---

## §1 — Las 9 reglas cardinales

### 1. Server-Only

Toda evaluación de regla ocurre en `supabase/functions/_shared/ruleEngine.ts` invocada por `process-system-events`. **El cliente jamás evalúa rules** — solo renderiza data publicada (rule sentences, history).

**Hoy:** ✅ Limpio. Swift no contiene `evaluateRule` ni lógica de matching. Formatters solo renderizan strings.

**Audit gate:** code review rechaza cualquier `switch trigger.eventType` en Swift que no sea purely display.

### 2. Deterministic

Engine evaluators leen SOLO del `RuleContext` que se les pasa. No `Date.now()` — usar `context.now` (snapshotted al inicio del cron loop). No random. No external HTTP calls salvo lecturas idempotentes a Supabase.

**Razón:** rule replays deben producir el mismo veredicto. Si la regla evaluada el 14 de mayo dispara fine, replay el 17 de mayo debe disparar el mismo fine.

### 3. Pure (No Arbitrary Mutation)

Toda consequence emite:
- **atom** (`record_system_event` o INSERT en atom table), o
- **workflow** (INSERT en `votes`, `pending_changes`, `user_actions`), o
- **canonical RPC** (`transfer_right`, `start_vote`, etc.) que internamente emite atom.

**Prohibido:** UPDATE directo a `resources`, `fines`, `members`, `groups` desde código de engine.

**Hoy violación F8:** `setBookingsLocked` (process-system-events/index.ts:403-446) hace `await supabase.from('resources').update({ metadata: nextMeta })` directo. Fix R7 — convertir en RPC `lock_asset_bookings(asset_id, rule_id, reason)` que emite `assetBookingsLocked` atom.

### 4. Idempotent

Cada consequence ejecución es marcada en `rule_evaluations` con `idempotency_key = sha1(rule_version_id || trigger_event_id || target_member_id || consequence_index)`.

**Protocol:**
1. Engine procesa event.
2. Engine determina rules aplicables.
3. Para cada (rule, target, consequence): compute idempotency_key.
4. `INSERT INTO rule_evaluations (..., idempotency_key)` — UNIQUE constraint short-circuits dupes.
5. Si INSERT succeeded → execute consequence (emit atom / start workflow / call RPC).
6. Si INSERT failed con unique_violation → consequence ya se ejecutó en run previo, skip.
7. Mark system_event as processed.

**Hoy violación F5:** El engine ejecuta consequences pero **nunca INSERT en rule_evaluations**. Cada sink reimplementa dedup ad-hoc:
- `proposeFine` check `fines_view` por (resource_id, user_id, rule_id) → ok
- `createUserAction` check existence → ok
- `setBookingsLocked` check current state → ok
- `bumpWaitlistPriority` check current → ok
- `emitWarning` — **ninguno** — duplicate warnings on retry

Fix R5 — wire the cron to INSERT rule_evaluations first.

### 5. Replayable

Dado el set de atoms (`system_events`) y el set de `rule_versions` activos en un momento, replaying el engine debe producir el mismo set de consequences.

**Implicación:** si necesitas re-evaluar un evento pasado bajo otra rule version, no se puede mutar atoms. Se crea una nueva rule_version, se re-procesa events targeted via cron, y los nuevos consequences emiten atoms nuevos (no re-emiten viejos).

### 6. Append-Only Audit (rule_evaluations)

`rule_evaluations` table (mig 00181) es atom-guarded (`rule_evaluations_atom_guard_trg` blocks UPDATE/DELETE). No es user-facing — RLS restringe SELECT a admins.

**Contract:**
- 1 row por (rule_version_id, trigger_event_id, target_member_id, consequence_index) evaluado.
- Carries `verdict` (matched/skipped), `consequences_emitted` (refs a atoms creados), `evaluator_version`, `evaluated_at`.

**No es activity feed** — para users, el atom emitido es el evento. `rule_evaluations` es debugging técnico.

### 7. Rules May Read Projections, Not Write

Rules evalúan condiciones leyendo `attendance_view`, `fund_balance_view`, etc. Una rule NUNCA escribe a una projection — projections son derivadas, no targetables.

Si una rule "actualiza un counter", el counter es projection derivada de atoms — la rule emite atoms, la projection se recomputa.

### 8. Rule Conditions Are Closed DSL

Condiciones se evalúan con un set fijo de operadores (`==`, `<=`, `in`, `between`) sobre variables tipadas (`actor`, `resource`, `trigger`, `now`, `count(projection)`). **No hay code arbitrario.**

Razón: el builder UX (Governance.md §0.5) compone shapes pre-validados. El usuario nunca escribe lógica.

### 9. Rule Versions Are Snapshots

Cada publish crea `rule_versions` row con `compiled` jsonb frozen. El engine evalúa contra el snapshot — no contra `rules.trigger`/`conditions`/`consequences` que pueden cambiar.

Desactivar rule = nueva version con `status='superseded'`. NUNCA `DELETE`.

**Hoy gap menor (F14):** `rule_versions.status` no está estrictamente guarded — el guard docstring promete "active → superseded/inactive only" pero el código permite cualquier valor pasing CHECK. Fix P3.

---

## §10 — Consequence Sink Contract

Toda nueva consequence agregada al engine sigue este shape:

```typescript
interface ConsequenceSink {
  // Called by engine for each (rule, target, consequence) tuple.
  // MUST be idempotent — second call with same idempotency_key is no-op.
  // MUST emit atom OR start workflow OR call canonical RPC.
  // MUST NOT directly UPDATE state tables.
  execute(args: {
    rule_version_id: uuid;
    trigger_event_id: uuid;
    target_member_id: uuid;
    target_resource_id: uuid;
    consequence_index: number;
    consequence_params: jsonb;
    context: RuleContext;
  }): Promise<void>;
}
```

**Fix R5 + R7 implica refactor:**

```typescript
async function evaluate(event: SystemEvent) {
  const rules = await loadApplicableRules(event);
  const sorted = sortByPrecedence(rules);

  for (const rule of sorted) {
    const targets = await rule.trigger.evaluate(event, rule, context);
    for (const target of targets) {
      const conditionsPassed = await rule.conditions.evaluate(target, context);
      if (!conditionsPassed) continue;

      for (let i = 0; i < rule.consequences.length; i++) {
        const idempotencyKey = sha1(
          `${rule.version_id}|${event.id}|${target.member_id}|${i}`
        );
        const inserted = await supabase
          .from('rule_evaluations')
          .insert({
            rule_version_id: rule.version_id,
            trigger_event_id: event.id,
            target_member_id: target.member_id,
            consequence_index: i,
            idempotency_key: idempotencyKey,
            verdict: 'matched',
            evaluator_version: ENGINE_VERSION,
            evaluated_at: context.now,
          })
          .select()
          .maybeSingle();
        if (!inserted.data) continue; // dup, skip

        await sink[rule.consequences[i].type].execute({
          rule_version_id: rule.version_id,
          trigger_event_id: event.id,
          target_member_id: target.member_id,
          target_resource_id: target.resource_id,
          consequence_index: i,
          consequence_params: rule.consequences[i].params,
          context,
        });
      }
    }
  }
}
```

---

## §11 — Forbidden patterns

| Pattern | Why forbidden |
|---|---|
| `UPDATE resources SET metadata = ...` from edge function | F8 violation — bypass RPC + atom |
| `UPDATE fines SET ...` from engine | Mutates instrument; instrument must derive from atoms via fines_view |
| `Date.now()` in evaluator | Non-deterministic; breaks replay |
| `fetch(externalUrl)` in evaluator | Non-idempotent network |
| Random in condition or target selection | Non-deterministic |
| Reading from `rule_evaluations` for engine logic | rule_evaluations is audit, not state — leads to feedback loops |
| Consequence emits sin INSERT en rule_evaluations primero | Loses idempotency |
| Loop detection by counter on `resources.metadata.rule_run_count` | Mutable counter is heresy; use rule_evaluations existence check |
| Synthetic events bypass system_events_atom_guard | All atoms go through `record_system_event` or canonical inserters |
| Client-side rule evaluation (Swift `evaluate`) | Engine is server-only |

---

## §12 — `rule_evaluations` schema (mig 00181 reference)

```sql
CREATE TABLE public.rule_evaluations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_version_id uuid NOT NULL REFERENCES rule_versions(id),
  trigger_event_id uuid NOT NULL REFERENCES system_events(id),
  target_member_id uuid,
  consequence_index int NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  verdict text NOT NULL CHECK (verdict IN ('matched','skipped','error')),
  consequences_emitted jsonb,  -- array of atom ids / workflow ids created
  evaluator_version text,
  evaluated_at timestamptz NOT NULL DEFAULT now(),
  error_payload jsonb
);

ALTER TABLE public.rule_evaluations ENABLE ROW LEVEL SECURITY;
CREATE POLICY rule_evaluations_admin_read ON public.rule_evaluations
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM group_members gm
      JOIN rule_versions rv ON rv.id = rule_evaluations.rule_version_id
      JOIN rules r ON r.id = rv.rule_id
      WHERE gm.user_id = auth.uid()
        AND gm.group_id = r.group_id
        AND (gm.role = 'admin' OR gm.role = 'founder')
    )
  );

-- Guard
CREATE TRIGGER rule_evaluations_atom_guard_trg
  BEFORE UPDATE OR DELETE ON public.rule_evaluations
  FOR EACH ROW EXECUTE FUNCTION public.atom_no_mutation_guard();
```

---

## §13 — Scope precedence (engine)

```
occurrence > resource > series > resource_type > capability > group > global_default
```

Implementation: `selectMostSpecificPerSlug` in `ruleEngine.ts:626`.

**Conflict types:**
1. **Precedencia natural** — same slug at multiple scopes → engine picks most-specific. No user-visible conflict.
2. **Real conflict** — multiple rules at SAME scope, SAME trigger, contradictory consequences → blocked at publish time (mig P0 contract).

Beta 1 detects conflict type 2 only (Governance.md §1.6).

---

## §14 — Test contracts

- `test_engine_is_deterministic` — same events + same rule_versions → same outputs.
- `test_engine_does_not_mutate_state_tables` — scan all consequence sinks for `.update()` calls on non-atom tables; should fail until R7.
- `test_engine_writes_rule_evaluations` — POST-R5 — every consequence ejecutado tiene su row.
- `test_engine_skips_duplicate_idempotency_key` — POST-R5 — second pass on same event does nothing.
- `test_engine_emit_warning_does_not_duplicate_on_retry` — POST-R5.
- `test_engine_propose_fine_does_not_duplicate_on_retry` — exists implicitly, formalize.
- `test_rule_versions_status_only_active_to_superseded_or_inactive` — POST-P3.
- `test_engine_replay_against_past_events_produces_same_atoms` — replay test.
- `test_client_does_not_evaluate_rules` — grep Swift for evaluator functions.

---

## §15 — Failure handling

- Cron crashes mid-batch: events without `processed_at` retry on next tick. Idempotency keys prevent dup consequences (post-R5).
- Consequence sink throws: error logged, `rule_evaluations.verdict='error'` + `error_payload`, system_event NOT marked processed → retry. Operator alert post-N failures.
- Atom emission fails: bubble up, system_event not marked processed.
- Rule_evaluations INSERT fails (unique violation): treat as "already done", proceed.
- Rule_evaluations INSERT fails (other): treat as engine fault, do not execute consequence, retry.

---

## §16 — AI integration

AI may:
- Propose new rule (generate draft `rules` row, status='proposed').
- Suggest rule changes (generate diff for admin review).
- Summarize rule_evaluations for admin debugging.
- Detect potential rule conflicts during draft.

AI may NOT:
- Publish rules directly (admin must confirm).
- Execute consequences directly.
- Override rule engine veredicts.
- Mutate rule_versions.compiled.

This mirrors Governance.md §0 principle 5 — "AI propose, never publish".

---

## §17 — Forbidden new patterns

- "Rule action that creates other rules" — recursion path; out of scope.
- "Rule that calls external API" — non-deterministic.
- "Rule that mutates rule_evaluations" — audit corruption.
- "Rule with implicit fallthrough" — every consequence must be explicit.
- "Rule that depends on UI state" — engine is headless.
